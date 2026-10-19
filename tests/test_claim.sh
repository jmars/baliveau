#!/bin/sh
# tests/test_claim.sh — THE ACCEPTANCE for the JUDGE SEAT (tools/fx-claim.c;
# claim unit S1, plan handoff-claim-rev-plan).
#
# The seat assembles THE TRIPLE per published GENERATION — the claim (the two
# extraEtc rows that rode into the generation at /etc/fx-claim.tsv +
# /etc/fx-claim.le), the VERDICT (ONE policy/eval_claim.py subprocess; the
# evaluation is free LE, the seat owns the RECORD) and the OUTCOME (the
# .operator activate row + the generation facts) — and persists it in the
# host-side obs file <store>.fx-claim-obs under fx-audit's observation
# discipline VERBATIM.  Every arm below says what makes it FAIL; an arm that
# cannot fail is decoration.
#
#   ENROLL     the FIRST-EVER run records what it sees and compares nothing
#              (STATED in the output, never silent); a claimless generation
#              at enrollment is `claimless` — stated, not a finding.  FAIL:
#              an enrollment that behaves like a comparison, or an absence
#              read as a finding before any baseline exists.
#   DERIVES    the honest claim derives: `record ... verdict=ok`, exit 0.
#              FAIL: a deriving claim refused, or a refused one ok'd.
#   NOCLAIM    a generation WITHOUT a claim arriving POST-enrollment is a
#              NAMED finding (no-claim, exit 1) — the §1a gap-3 error is
#              reading that absence as "none occurred".  It keeps firing
#              (the observation is not rewritten under a disagreement with
#              itself) until --re-enroll.  FAIL: exit 0, or the class
#              un-named.
#   OBS        STABILITY: a second coherent run rewrites the observation
#              BYTE-IDENTICAL (cmp; the obs carries no wall-clock); a
#              TAMPERED observation (a verdict line edited) fires
#              `verdict-rewritten` on the next run and is NOT rewritten;
#              --re-enroll resets the baseline.  A claimless baseline whose
#              retained dir GAINS claim bytes fires `claim-rewritten` BY
#              NAME (the round-2 sha-blank nit — the comparison must not
#              skip a "-"-sha row).  FAIL: a re-run that drifts, a tamper
#              that passes silently, a reset that does not, or a rewrite
#              absorbed by a blank sha.
#   ARMS       every named disagreement class, each on its own generation of
#              one store built by the REAL writers: stale-world (BINDING 3:
#              the row's from_version names a different world than the one
#              live at the .operator row's from-version — a CONTENT join),
#              premise-false, vacuous-differs (spine PRESENT
#              and the differs guard PRESENT — S0 a4c's shape), vacuous-
#              unconnected, vacuous-selfloop, malformed-claim (LOUD: an
#              unparsable row is refused by name, never read as claimless),
#              head-forgery, and the honest derives control beside them.
#   ROLLBACK   the round-2 BLOCKER, armed: a rollback re-activating the
#              IDENTICAL root bytes lands the SAME genhash again at a higher
#              version (the substrate adopts the existing dir), and an
#              honest claim naming it — the world live at the op row's
#              from-version — must DERIVE.  The pre-fix join (first-
#              appearance version NUMBER vs the op row's from-version) fired
#              stale-world on exactly this claim.  FAIL: stale-world on the
#              honest claim, or the fixture stops separating the two joins
#              (the pinned before: tests/fixtures/claims/
#              rollback-join-before.txt, cmp'd every run).
#   SKIPPED    a claim generation landed by a publish whose .operator
#              outcome is NOT ok is verdict=skipped — STATED, never judged
#              (no eval block runs; exit 0; the note names the outcome).
#              FAIL: the generation judged anyway, or the class unnamed.
#   RETRY      the round-3 BLOCKER, armed: a generation whose FIRST landing
#              carries a non-ok outcome (dhake-failed — the activation
#              committed, the live-root reapply failed) and whose operator
#              RETRY re-lands the SAME genhash ok (the writer's own shapes,
#              init.zig:3952/:3965) is LIVE and ok-published — its claim
#              MUST be judged.  The pre-fix binding (the FIRST landing's
#              row alone decides the outcome) answered verdict=skipped on
#              it FOREVER: zero eval lines, exit 0, the seat never called.
#              The arm also guards the measured TRAP: binding 3 must bind
#              the FIRST landing's row (from-version = the root), NOT the
#              ok row's (whose from-version IS the claim's own generation)
#              — the wrong join would fire stale-world on the honest
#              claim.  FAIL: verdict=skipped or stale-world on the retried
#              generation, or no eval block under it (the pinned before:
#              tests/fixtures/claims/retry-skip-before.txt, cmp'd every
#              run).  The single-landing SKIPPED arm beside it keeps the
#              skipped class real.
#   ROLLBACK-REC  the round-4 BLOCKER, armed: the claim generation's only ok
#              landing is a CONTROL-CHANNEL ROLLBACK to its version (the
#              reviewer's measured sequence: root ok; the claim lands behind
#              a dhake-failed publish; a later gen goes ok; `fxctl rollback`
#              returns to the claim's version — the row is init.zig:4056's
#              exact shape: arg = the target operand, outcome ok, from = the
#              current before, to-version = the current after the wrap ==
#              the target).  The pre-fix filter read ACTIVATE rows only, so
#              the live generation's ONLY rows carried dhake-failed:
#              verdict=skipped FOREVER, zero eval lines, exit 0 — the seat
#              never called on the live generation.  The fixed filter reads
#              the writer's terminal rollback rows (refused/unverified
#              rollbacks and shutdown rows carry to='-' and land nothing).
#              Binding 3 must still bind the FIRST landing's ACTIVATE row
#              (op-from = the root), never the rollback row's from-version
#              (the world the rollback moved FROM — the measured trap, one
#              arm further).  FAIL: verdict=skipped on the rollback-
#              published generation, no eval block, op-from rebound to the
#              rollback's from-world, or stale-world (the pinned before:
#              tests/fixtures/claims/rollback-land-before.txt, cmp'd every
#              run — re-recorded ONCE, at the S3 re-measure, on exactly one
#              line: the ok ROLLBACK row's cite init.zig:3920 -> :4056, the
#              diff read before it was applied).
#   CAP        the round-4 SHOULD-FIX, armed: a journal PAST MAX_OP_ROWS
#              dies LOUDLY, naming the cap and why the tail matters (the
#              newest rows — the re-landings — live at the tail; every
#              sibling cap dies the same way).  The pre-fix seat kept the
#              FIRST 4096 rows and dropped the tail SILENTLY, which
#              resurrects the skipped-forever blocker (measured: 4094
#              writer-shaped fillers + the ok retry row past the cap ->
#              skipped, zero evals, exit 0).  FAIL: a silent answer on a
#              capped journal (the M7 mutant executes exactly that).
#   MUTANTS    each blind on exactly its own fixture (a `cmp` guard makes a
#              sed that matches nothing FAIL the gate instead of comparing a
#              file to itself):
#     M1  the POLICY mutant DROPS the differs guard:
#         `, !landed_config(C2)` deleted from the pinned rule text — then the
#         vacuous-differs arm DERIVES and the honest arm's answer is
#         UNCHANGED (the guard is what refuses that claim).
#     M2  the SEAT mutant deletes the one `binding3_opfrom(...)` call line —
#         then the stale-world arm's class becomes the evaluator's own
#         verdict (it derives: its spine and guard hold), and the other
#         arms' classes are UNCHANGED.
#     M3  the SEAT mutant replaces the ENROLLMENT BOUNDARY
#         (`int enroll = !g_have_obs || g_reenroll;` -> `int enroll = 1;`) —
#         then every run re-enrolls and the claimless generation reads
#         none-occurred: the no-claim arm's exit flips 1 -> 0.  THE §1a
#         gap-3 ERROR, executed.
#     M4  the EVALUATOR mutant drops the head check (the S0 A6 sed) — then
#         the head-forgery arm derives, and the honest arm is UNCHANGED.
#     M5  the SEAT mutant restores the ROUND-2 op-row binding (the row of
#         the FIRST landing alone decides the outcome — the one line the
#         round-3 fix changed) — then the RETRY arm's generation answers
#         verdict=skipped again with NO eval block (the round-3 blocker,
#         executed: the arm FAILS against the pre-fix seat), while the
#         single-landing SKIPPED arm and the ROLLBACK arm's answers are
#         UNCHANGED (the mutant is blind on exactly the retry fixture).
#     M6  the SEAT mutant restores the ROUND-3 landing filter (ACTIVATE
#         rows only — the one line the round-4 fix changed) — then the
#         ROLLBACK-REC arm's generation answers verdict=skipped again with
#         NO eval block (the round-4 blocker, executed: the arm FAILS
#         against the pre-fix seat), while the RETRY, single-landing
#         SKIPPED and ROLLBACK arms' answers are UNCHANGED (every journal
#         there is activate-only; the mutant is blind on exactly the
#         rollback-recovery fixture).
#     M7  the SEAT mutant restores the SILENT tail-drop at MAX_OP_ROWS
#         (the one line the round-4 fix changed) — then the CAP arm's ok
#         retry row (past the cap) VANISHES and the live generation is
#         skipped again with zero eval lines, exit 0 (the should-fix's
#         silent failure mode, executed), while the fixed seat dies loudly
#         on the same store.
#     M8  the SEAT mutant DELETES the round-5 UNJOURNALED-LANDINGS bound
#         line (the one printf) — then the bound is ABSENT from the seat's
#         stdout while everything else answers identically: the arm proves
#         the bound both prints (on every fixed run) and can be MISSING (a
#         bound whose absence is unobservable is decoration).
#   BOUND-PRINT  the round-5 UNJOURNALED-LANDINGS bound, stated: the seat
#              judges JOURNALED landings only, and the writer's own header
#              (operator_journal.zig:174-183) enumerates landing moves that
#              write NO .operator row — the AUTOMATIC .recovery roll-forward
#              (init.zig:1798; .recovery is the AUDIT's file and means
#              AUTOMATIC, so the seat does NOT read it — DECISION B), a
#              host-side `fxstore rollback`, `rollback --hard`, and a
#              hand-edited CURRENT.  DIRECTION: a claim generation first
#              landed with a non-ok outcome and later RE-LANDED by one of
#              these stays verdict=skipped while live and ok-booted — its
#              claim is never judged, silently.  The bound PRINTS as a
#              `bound<TAB>unjournaled-landings` line on every run
#              (fx-report's idiom, bound<TAB>id<TAB>text).  FAIL: the line
#              absent from the fixed seat's stdout (M8 executes exactly
#              that removal).
#   PIN        the PINNED PRE-FIX CONTROL: the prose-reader (the pre-fix
#              world: whoever could read /etc/fx-claim.tsv took its word)
#              ACCEPTS the vacuous claim — recorded as the before in
#              tests/fixtures/claims/prose-reader-before.txt and cmp'd
#              BYTE-EXACT against the live prose-read of the same fixture
#              every run, so the pin's DOMAIN is the prose surface: the pin
#              carries the claim row's raw bytes and carries NO judge output
#              (no `verdict` line — it predates the judge).  The judge's
#              refusal of the same shape (the ARMS store's vacuous-differs
#              generation) is the after.  FAIL: the pin drifted, the pin
#              silently pins the judge's output, or the live read diverges.
#
# FIXTURE HONESTY: the stores are built by the REAL writers — activate_paths,
# fx-activate (host-built), fxstore itself — with the claim riding INTO each
# activation as the two extraEtc rows.  .operator is fx-init's file and
# fx-init does not run host-side: the gate writes it in the writer's exact
# shape (operator_journal.zig's header, abridged verbatim-where-it-defines-
# the-shape, exactly as tests/test_fx_report.sh does) and DECLARES that.  One
# activation (the vacuous-differs generation) deliberately carries NO row (a
# publish on a non-nonce boot is unjournaled — the runtime-record closure
# writes rows only then): the seat's from-version cross-check is skipped,
# STATED on its record line, and the EVALUATOR's differs guard is what
# refuses that claim — which is exactly why the guard mutant M1 is visible
# on it.
#
# STATED BOUNDS (printed on every run, never implicit):
#   * the judge and its evaluator run HOST-SIDE — a DEPLOYMENT STOPGAP,
#     labelled: same lexicon, same policy, same claim bytes, same record;
#     the committed target is in-guest (qemu lane, x64 via QBE).
#   * le's proper nouns are letters-only, so the fixture rows carry real
#     store symbols ONLY in the row (from_version / S_from are engine
#     symbols injected from the TSV; the .le arguments use variables and
#     never spell a hash).
#   * a no-op activation (a config byte-identical to the live one) adds a
#     VERSION but no GENERATION (content-addressed): the seat judges
#     generations — such a version is visible in the timeline and to the
#     reporter (S2), and to no verdict here.
set -u

fail() { echo "test_claim: FAIL: $*" >&2; exit 1; }
skip() { echo "test_claim: SKIP ($*)"; exit 77; }
ok()   { echo "test_claim: OK $*"; }

cd "$(dirname "$0")/.." || fail "cannot cd to the repo root"
REPO="$PWD"

command -v python3 >/dev/null 2>&1 || fail "python3 is required (the evaluator is Python)"
command -v cc >/dev/null 2>&1 || skip "cc not found"
command -v sed >/dev/null 2>&1 || skip "sed not found"

# ── sibling resolution: the repo's ONE policy (tests/test_sibling_paths.sh).
SIBS="${FX_SIBLINGS:-$(cd "$REPO/.." && pwd)}"
[ -d "$SIBS/fx-init" ] || [ -n "${FX_SIBLINGS:-}" ] || SIBS="$HOME/fixpoint-linux"

LE_ROOT="${LE_DIR:-}"
if [ -z "$LE_ROOT" ]; then
    for cand in "$SIBS/logical-english" "$REPO/../logical-english" "$HOME/logical-english"; do
        if [ -f "$cand/le/__init__.py" ]; then LE_ROOT="$cand"; break; fi
    done
fi
[ -f "$LE_ROOT/le/__init__.py" ] || \
    fail "no le checkout (set LE_DIR; looked at \$FX_SIBLINGS/$SIBS, \$REPO/.., \$HOME/logical-english)"
export LE_DIR="$LE_ROOT"

DLB_PY="${DLB_PATH:-}"
if [ -z "$DLB_PY" ]; then
    for cand in "$SIBS/datalog-dafsa/python" "$REPO/../datalog-dafsa/python" "$HOME/fixpoint-linux/datalog-dafsa/python"; do
        if [ -f "$cand/dlb/__init__.py" ]; then DLB_PY="$cand"; break; fi
    done
fi
[ -f "$DLB_PY/dlb/__init__.py" ] || \
    fail "no datalog-dafsa python binding (set DLB_PATH); the evaluator needs dlb"
export DLB_PATH="$DLB_PY"
echo "test_claim: le at $LE_ROOT; the engine binding at $DLB_PY"

FXSTORE="${FXSTORE_BIN:-$SIBS/fxstore/zig-out/bin/fxstore}"
[ -x "$FXSTORE" ] || skip "fxstore binary missing at $FXSTORE (set FX_SIBLINGS or FXSTORE_BIN, or build the sibling)"
"$FXSTORE" --help 2>&1 | grep -q 'fxstore facts' || skip "fxstore at $FXSTORE predates 'facts' (rebuild the sibling)"
grep -aq generation_config "$FXSTORE" || skip "fxstore at $FXSTORE predates the generation_config schema row (rebuild the sibling)"

INIT="${FX_INIT_REPO:-$SIBS/fx-init}"
[ -d "$INIT" ] || skip "fx-init checkout not found at $INIT (set FX_SIBLINGS or FX_INIT_REPO)"
# NOTE (S3 re-measure): this gate cites fx-init's init.zig BY LINE in its
# prose (the writer's .operator row shapes: the ctrl arms' terminal rows, the
# soft rollback, the recovery row) and there is NO blob pin here — the four
# pins live in test_fx_audit.sh, test_fx_select.sh, test_fx_report.sh and
# qemu-agent-b2.sh.  Those cites were re-measured by hand against blob
# bf8fa631 (fx-init bb0642f, 5978 lines) and each was verified to land on the
# append it names; nothing makes this file's drift LOUD.  Reported, not
# widened: adding a pin would add an assertion to this gate.
DL="$SIBS/datalog-dafsa/zig-out/lib"
[ -f "$DL/libdatalog.so" ] || skip "libdatalog.so missing at $DL (set FX_SIBLINGS)"

ZB="$REPO/build/guest-payload/init-x86_64-musl/bin"
if [ ! -x "$ZB/activate_paths" ] || [ ! -x "$ZB/fx-activate" ]; then
    command -v zig >/dev/null 2>&1 || skip "$ZB binaries absent and zig not found to build them"
    echo "test_claim: building fx-init's binaries (x86_64-linux-musl)"
    ( cd "$INIT/zig" && zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe \
        -p "$REPO/build/guest-payload/init-x86_64-musl" \
        --cache-dir "$REPO/build/guest-payload/zig-init-cache" ) || fail "fx-init zig build failed"
fi
[ -x "$ZB/activate_paths" ] || fail "no $ZB/activate_paths"
[ -x "$ZB/fx-activate" ] || fail "no $ZB/fx-activate"
grep -aq generation_config "$ZB/fx-activate" || {
    skip "staged fx-activate at $ZB predates the config link (fx-init 1399dbd) — the staging froze on an OLD fx-init; rm -rf build/guest-payload/init-x86_64-musl and re-run to rebuild it"
}

# ── the seat itself, and the STALE-BINARY guard (the audit gate's discipline:
#    the artifact the gate drives must be the artifact built from THIS source)
make -s build/fx-claim >/dev/null || fail "cannot build build/fx-claim"
CLAIM="$REPO/build/fx-claim"
[ -x "$CLAIM" ] || fail "no $CLAIM"
[ "$CLAIM" -nt "$REPO/tools/fx-claim.c" ] || fail "$CLAIM is older than tools/fx-claim.c — a stale cached binary answered for the seat; rm -rf build and re-run"
grep -aq "fx-claim-observation 1" "$CLAIM" || fail "STALE BINARY: $CLAIM does not contain this source's observation format marker"
grep -aq "no-operator-row-cross-check-skipped" "$CLAIM" || fail "STALE BINARY: $CLAIM does not contain this source's binding-3 skip marker"
grep -aq "the claim's world model does not exist" "$CLAIM" || fail "STALE BINARY: $CLAIM does not contain this source's from_version-resolution marker"
grep -aq "names a different world than the one this" "$CLAIM" || fail "STALE BINARY: $CLAIM does not contain this source's binding-3 content-join marker (a pre-content-join binary answered)"
grep -aq "no-operator-row-for-first-landing" "$CLAIM" || fail "STALE BINARY: $CLAIM does not contain this source's first-landing binding marker (a pre-round-3 binary answered)"
grep -aq "FUTURE writer action" "$CLAIM" || fail "STALE BINARY: $CLAIM does not contain this source's round-4 landing-set marker (a pre-round-4, activate-only binary answered)"
grep -aq "unjournaled-landings" "$CLAIM" || fail "STALE BINARY: $CLAIM does not contain this source's round-5 unjournaled-landings bound marker (a pre-round-5 binary answered)"

POLICY="$REPO/policy/claims-policy.dl"
FIX="$REPO/tests/fixtures/claims"
[ -f "$POLICY" ] || fail "missing $POLICY (make policy-artifact)"

TAB="$(printf '\t')"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fxclaim.XXXXXX")" || fail mktemp
if [ "${FX_CLAIM_KEEP:-0}" = "1" ]; then
    trap 'echo "test_claim: scratch kept at $WORK"' EXIT
else
    trap 'rm -rf "$WORK"' EXIT
fi
mkdir -p "$WORK/rows" || fail mkdir

# ── the package set (the report gate's provisioning shape, toolchain-free) ─
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
    ps_pkg dhake       "$SRC/tool"
    ps_pkg fx-init     "$SRC/tool"
    ps_pkg fxctl       "$SRC/tool"
    ps_pkg fx-activate "$SRC/tool"
    echo "  ] }"
} > "$WORK/pkgset.dhall"
PS="$WORK/pkgset.dhall"

# write_cfg OUT HOSTNAME TSVFILE LEFILE — a config whose extraEtc carries the
# two claim rows (the rows ride INTO the activation's input bytes, BEFORE,
# structural: the generation retains them at etc/fx-claim.tsv + .le)
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
write_cfg_nc() { # write_cfg_nc OUT HOSTNAME — a config with NO claim
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

STORE=""
act() { # act CFGFILE -> echoes "<version> <genhash>"
    _o=$(LD_LIBRARY_PATH="$DL" "$ZB/fx-activate" --store "$STORE" --package-set "$PS" \
        --config "$1" 2>&1) || fail "fx-activate failed: $_o"
    _v=$(echo "$_o" | sed -n 's/.*activated \([0-9a-f]*\) as version \([0-9][0-9]*\).*/\2 \1/p' | head -1)
    [ -n "$_v" ] || fail "no version from fx-activate: $_o"
    echo "$_v"
}
sha_of() { sha256sum "$1" | cut -d' ' -f1; }

provision() { # provision STOREDIR — activate_paths + the src dirs it names
    STORE="$1"
    mkdir -p "$STORE"
    P=$(LD_LIBRARY_PATH="$DL" "$ZB/activate_paths" --store "$STORE" --package-set "$PS" \
        dhake fx-init fxctl fx-activate) || fail "activate_paths failed: $P"
    for _pd in $P; do mkdir -p "$STORE/$_pd" || fail "cannot create $_pd"; done
}

run_claim() { # run_claim OUTFILE STORE [extra seat args...] — the seat's rc on stdout
    local out=$1 store=$2; shift 2
    "$CLAIM" --store "$store" --policy "$POLICY" --fxstore "$FXSTORE" "$@" \
        >"$out" 2>"$out.err"
    echo $?
}

rec_of() { # rec_of OUTFILE GENHASH — the record line for one generation
    grep "^record${TAB}$2${TAB}" "$1"
}

# an .operator journal in the writer's shape (fixture honesty: header abridged
# verbatim-where-it-defines-the-shape, exactly as test_fx_report.sh does;
# QUOTED heredoc — the real header contains backticks)
write_operator() { # write_operator STOREDIR  (data rows are appended by the caller)
    cat > "$1/.operator" <<'OPHDR'
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
}

oprow() { # oprow STOREDIR EPOCH CFGPATH FROM TO
    echo "$2 activate $3 ok $4 $5 gatenonce" >> "$1/.operator"
}
oprow_x() { # oprow_x STOREDIR EPOCH CFGPATH FROM TO OUTCOME — a refused/failed publish
    echo "$2 activate $3 $6 $4 $5 gatenonce" >> "$1/.operator"
}
oprow_rb() { # oprow_rb STOREDIR EPOCH TARGET FROM TO OUTCOME — the writer's
             # ROLLBACK row (init.zig:4013/:4056: the ARG is the target-version
             # operand; the to-version is the current AFTER the wrap — the
             # RESULT version the SOFT rollback publishes (store.zig:1240:
             # two new versions, CURRENT advances monotonically), its
             # snapshot naming the rolled-back-to genhash — NOT the target
             # operand; refused/unverified rollbacks carry to='-' instead.
             # This fixture passes the claim's OWN version as to-version,
             # which row_lands measures identically (content-based) — the
             # reviewer's round-4 result-version shape judged the same)
    echo "$2 rollback $3 $6 $4 $5 gatenonce" >> "$1/.operator"
}

# ══ ENROLL / DERIVES / NOCLAIM / OBS: the store-ok lifecycle ═══════════════
echo "test_claim: ── the store-ok lifecycle (enroll, derives, obs stability, no-claim, tamper) ──"

provision "$WORK/store-ok"
write_cfg_nc "$WORK/cfg-root.dhall" repbox-root
write_cfg_nc "$WORK/cfg-noclaim.dhall" repbox-noclaim

# the root generation: claimless (the world's start — nothing to diff from)
read _VR GR < <(act "$WORK/cfg-root.dhall")
SHAROOT=$(sha_of "$WORK/cfg-root.dhall")
# the derives claim: from the root generation, at the root's landed config —
# the row exists BEFORE the config that carries it (it names the ROOT, never
# its own container: a row cannot name the sha of the bytes it rides in)
printf 'claima\tcfg-diff-ok\t%s\t%s\n' "$GR" "$SHAROOT" > "$WORK/rows/ok.tsv"
write_cfg "$WORK/cfg-ok.dhall" repbox-ok "$WORK/rows/ok.tsv" "$FIX/good.le"
read _VB GB < <(act "$WORK/cfg-ok.dhall")

write_operator "$WORK/store-ok"
oprow "$WORK/store-ok" 100 "$WORK/cfg-root.dhall"   -  "$_VR"
oprow "$WORK/store-ok" 110 "$WORK/cfg-ok.dhall"  "$_VR" "$_VB"

rc=$(run_claim "$WORK/out-ok1" "$WORK/store-ok")
[ "$rc" = 0 ] || fail "ENROLL: the first-ever run on a coherent store must exit 0, got $rc ($(cat "$WORK/out-ok1.err"))"
grep -q "ENROLLMENT: first-ever observation" "$WORK/out-ok1" || fail "ENROLL: the enrollment is not STATED in the output"
rec_of "$WORK/out-ok1" "$GR" | grep -q "verdict=claimless" || fail "ENROLL: the claimless root generation is not stated claimless — $(rec_of "$WORK/out-ok1" "$GR")"
rec_of "$WORK/out-ok1" "$GB" | grep -q "verdict=ok" || fail "DERIVES: the honest claim did not derive — $(rec_of "$WORK/out-ok1" "$GB")"
grep -q "^eval${TAB}verdict${TAB}derives${TAB}justified(claima)" "$WORK/out-ok1" || fail "DERIVES: the evaluator's verdict line is not carried verbatim"
grep -q "spine${TAB}generation_config" "$WORK/out-ok1" || fail "DERIVES: the record does not name the store spine it read"
ok "enroll-stated + derives-ok (root claimless, ok claim derives; exit 0)"

# OBS STABILITY: the second run compares, is coherent, and rewrites the
# observation BYTE-IDENTICAL (no wall-clock in the record)
cp "$WORK/store-ok.fx-claim-obs" "$WORK/obs-run1"
rc=$(run_claim "$WORK/out-ok2" "$WORK/store-ok")
[ "$rc" = 0 ] || fail "OBS: the second coherent run must exit 0, got $rc"
cmp -s "$WORK/obs-run1" "$WORK/store-ok.fx-claim-obs" || fail "OBS: the re-run's observation is not byte-identical — the record carries something a function of the store's bytes is not (wall-clock? ordering?)"
grep -q "ENROLLMENT:" "$WORK/out-ok2" && fail "OBS: the second run claims to enroll — the enrollment boundary leaked"
ok "obs byte-identical re-run (cmp)"

# NOCLAIM: a generation without a claim arriving POST-enrollment
read _VH GH < <(act "$WORK/cfg-noclaim.dhall")
oprow "$WORK/store-ok" 120 "$WORK/cfg-noclaim.dhall" "$_VB" "$_VH"
rc=$(run_claim "$WORK/out-ok3" "$WORK/store-ok")
[ "$rc" = 1 ] || fail "NOCLAIM: a claimless generation post-enrollment must exit 1, got $rc"
grep -q "^finding${TAB}no-claim${TAB}$GH${TAB}" "$WORK/out-ok3" || fail "NOCLAIM: the no-claim finding is not named for $GH"
grep -q "none occurred" "$WORK/out-ok3" || fail "NOCLAIM: the finding does not name the §1a gap-3 error it guards"
cmp -s "$WORK/obs-run1" "$WORK/store-ok.fx-claim-obs" || fail "NOCLAIM: the observation was rewritten under a disagreement with itself"
ok "no-claim post-enrollment (exit 1, named, obs not rewritten)"

# TAMPER: a verdict line edited in the observation fires verdict-rewritten
sed -i -e "s/verdict ok claim-sha/verdict ok-rewritten claim-sha/" "$WORK/store-ok.fx-claim-obs"
grep -aq "ok-rewritten" "$WORK/store-ok.fx-claim-obs" || fail "TAMPER setup: the sed matched nothing"
rc=$(run_claim "$WORK/out-ok4" "$WORK/store-ok")
[ "$rc" = 1 ] || fail "TAMPER: a tampered observation must exit 1, got $rc"
grep -q "^finding${TAB}verdict-rewritten${TAB}$GB${TAB}" "$WORK/out-ok4" || fail "TAMPER: verdict-rewritten did not fire for the tampered generation"
grep -aq "ok-rewritten" "$WORK/store-ok.fx-claim-obs" || fail "TAMPER: the observation was REWRITTEN over the tamper (it must keep reporting until acted on)"
ok "tampered obs fires verdict-rewritten (and is not rewritten)"

# the way out: --re-enroll resets the baseline
rc=$(run_claim "$WORK/out-ok5" "$WORK/store-ok" --re-enroll)
[ "$rc" = 0 ] || fail "RE-ENROLL: --re-enroll must reset the baseline and exit 0, got $rc"
grep -aq "ok-rewritten" "$WORK/store-ok.fx-claim-obs" && fail "RE-ENROLL: the tampered verdict survived the reset"
rec_of "$WORK/out-ok5" "$GB" | grep -q "verdict=ok" || fail "RE-ENROLL: the honest claim's verdict is not ok after the reset"
ok "--re-enroll resets the baseline"

# SHA-BLANK: a claimless-baseline generation whose retained dir GAINS claim
# bytes.  The obs row legitimately records sha="-" for it; before the
# hardening the claim-rewritten comparison SKIPPED such a row (the nit the
# round-2 review named: an obs editor could blank the sha and have a
# rewrite absorbed), leaving only verdict-rewritten — which fires here only
# because the class would change too.  The arm names claim-rewritten
# SPECIFICALLY, so dropping the hardening fails it.  Fixture honesty: like
# the vacuous-differs generation, the rows are hand-placed into the
# retained generation dir (a genhash is content-addressed — its claim bytes
# cannot APPEAR through any real activation).
GENDIR_OK="$WORK/store-ok/$GH-system-generation/etc"
[ -d "$GENDIR_OK" ] || fail "SHA-BLANK: no retained etc/ for the claimless generation $GH"
cp "$WORK/rows/ok.tsv" "$GENDIR_OK/fx-claim.tsv"
cp "$FIX/good.le" "$GENDIR_OK/fx-claim.le"
rc=$(run_claim "$WORK/out-ok6" "$WORK/store-ok")
[ "$rc" = 1 ] || fail "SHA-BLANK: claim bytes appearing under a claimless baseline must exit 1, got $rc"
grep -q "^finding${TAB}claim-rewritten${TAB}$GH${TAB}" "$WORK/out-ok6" || fail "SHA-BLANK: claim-rewritten did not fire for the blank-sha baseline (the hardening is gone) — $(grep "^finding" "$WORK/out-ok6" || echo NO-FINDINGS)"
ok "sha-blank hardening: a '-'-sha baseline gaining claim bytes fires claim-rewritten by name"

# ══ ARMS: every named disagreement class, each on its own generation ══════
echo "test_claim: ── the arms store (each named class its own generation) ──"

provision "$WORK/store-arms"
write_cfg_nc "$WORK/cfg-r.dhall" arms-root

# B: the derives control — from the root generation at the root's config
read VRB RB < <(act "$WORK/cfg-r.dhall")
SHAR=$(sha_of "$WORK/cfg-r.dhall")
printf 'claima\tcfg-diff-b\t%s\t%s\n' "$RB" "$SHAR" > "$WORK/rows/b.tsv"
write_cfg "$WORK/cfg-b.dhall" arms-b "$WORK/rows/b.tsv" "$FIX/good.le"
read VDB DB < <(act "$WORK/cfg-b.dhall")

# C: stale-world — the row's from_version is the ROOT generation while the
# activation actually came from B's version
printf 'claima\tcfg-diff-c\t%s\t%s\n' "$RB" "$SHAR" > "$WORK/rows/c.tsv"
write_cfg "$WORK/cfg-c.dhall" arms-c "$WORK/rows/c.tsv" "$FIX/good.le"
read VDC DC < <(act "$WORK/cfg-c.dhall")
SHAC=$(sha_of "$WORK/cfg-c.dhall")

# D: premise-false — the argument asserts a fact no store version records
printf 'claima\tcfg-diff-d\t%s\t%s\n' "$DC" "$SHAC" > "$WORK/rows/d.tsv"
write_cfg "$WORK/cfg-d.dhall" arms-d "$WORK/rows/d.tsv" "$FIX/premise-false.le"
read VDD DD < <(act "$WORK/cfg-d.dhall")
SHAD=$(sha_of "$WORK/cfg-d.dhall")

# E: vacuous-differs — the row names ITS OWN generation and ITS OWN landed
# config: the spine holds as-of that version and the differs guard is
# PRESENT (S0 a4c's exact shape).  MEASURED, structural: this shape is NOT
# realizable through extraEtc — S_from would have to be the sha256 of the
# very config bytes that carry the row (a preimage of its own container).
# So THIS ONE fixture's claim rows are placed into the retained generation
# dir BY THE GATE, in the claim's exact format, AFTER the real activation —
# declared here exactly like the .operator fixture honesty above (the other
# arms all ride in via extraEtc, as the mechanism intends).  Its activation
# also carries NO .operator row (declared: a non-nonce-boot publish is
# unjournaled): the seat's from-version cross-check is skipped, STATED, and
# the EVALUATOR's differs guard is what refuses the claim — which is why
# the guard mutant M1 is visible on exactly this fixture.
write_cfg_nc "$WORK/cfg-e.dhall" arms-e
read VDE DE < <(act "$WORK/cfg-e.dhall")
SHAE=$(sha_of "$WORK/cfg-e.dhall")
GENDIR="$WORK/store-arms/$DE-system-generation/etc"
[ -d "$GENDIR" ] || fail "E fixture: no retained etc/ in the generation dir"
printf 'claima\tcfg-diff-e\t%s\t%s\n' "$DE" "$SHAE" > "$GENDIR/fx-claim.tsv"
cp "$FIX/good.le" "$GENDIR/fx-claim.le"

# F: vacuous-unconnected — an argument that concludes an intermediate the
# policy never consumes
printf 'claima\tcfg-diff-f\t%s\t%s\n' "$DE" "$SHAE" > "$WORK/rows/f.tsv"
write_cfg "$WORK/cfg-f.dhall" arms-f "$WORK/rows/f.tsv" "$FIX/vacuous-unconnected.le"
read VDF DF < <(act "$WORK/cfg-f.dhall")
SHAF=$(sha_of "$WORK/cfg-f.dhall")

# G: vacuous-selfloop — the contention defined only in terms of itself
printf 'claima\tcfg-diff-g\t%s\t%s\n' "$DF" "$SHAF" > "$WORK/rows/g.tsv"
write_cfg "$WORK/cfg-g.dhall" arms-g "$WORK/rows/g.tsv" "$FIX/vacuous-selfloop.le"
read VDG DG < <(act "$WORK/cfg-g.dhall")
SHAG=$(sha_of "$WORK/cfg-g.dhall")

# M: malformed — something wearing the claim's path that is not a claim row
printf 'not a claim row\n' > "$WORK/rows/m.tsv"
write_cfg "$WORK/cfg-m.dhall" arms-m "$WORK/rows/m.tsv" "$FIX/good.le"
read VDM DM < <(act "$WORK/cfg-m.dhall")
SHAM=$(sha_of "$WORK/cfg-m.dhall")

# HF: head-forgery — the argument concludes a store template as a rule head
printf 'claima\tcfg-diff-hf\t%s\t%s\n' "$DM" "$SHAM" > "$WORK/rows/hf.tsv"
write_cfg "$WORK/cfg-hf.dhall" arms-hf "$WORK/rows/hf.tsv" "$FIX/head-forgery.le"
read VDHF DHF < <(act "$WORK/cfg-hf.dhall")

# the journal: the writer's shape; EVERY activation gets its row EXCEPT E's
# (declared: a non-nonce-boot publish is unjournaled)
write_operator "$WORK/store-arms"
oprow "$WORK/store-arms" 200 "$WORK/cfg-r.dhall"  -     "$VRB"
oprow "$WORK/store-arms" 210 "$WORK/cfg-b.dhall"  "$VRB" "$VDB"
oprow "$WORK/store-arms" 220 "$WORK/cfg-c.dhall"  "$VDB" "$VDC"
oprow "$WORK/store-arms" 230 "$WORK/cfg-d.dhall"  "$VDC" "$VDD"
# NO row for cfg-e's activation (declared)
oprow "$WORK/store-arms" 240 "$WORK/cfg-f.dhall"  "$VDE" "$VDF"
oprow "$WORK/store-arms" 250 "$WORK/cfg-g.dhall"  "$VDF" "$VDG"
oprow "$WORK/store-arms" 260 "$WORK/cfg-m.dhall"  "$VDG" "$VDM"
oprow "$WORK/store-arms" 270 "$WORK/cfg-hf.dhall" "$VDM" "$VDHF"

rc=$(run_claim "$WORK/out-arms" "$WORK/store-arms")
[ "$rc" = 1 ] || fail "ARMS: the arms store is full of refused claims — the seat must exit 1, got $rc"
grep -q "ENROLLMENT: first-ever observation" "$WORK/out-arms" || fail "ARMS: the first run must state its enrollment"

arm_rec() { # arm_rec GENHASH WANTCLASS LABEL
    rec_of "$WORK/out-arms" "$1" | grep -q "verdict=$2" || fail "ARMS $3: expected verdict=$2 — $(rec_of "$WORK/out-arms" "$1")"
}
arm_rec "$RB"  "claimless" "root-claimless"
arm_rec "$DB"  "ok" "derives-control"
arm_rec "$DC"  "stale-world" "stale-world"
arm_rec "$DD"  "premise-false" "premise-false"
arm_rec "$DE"  "justified-not-derived" "vacuous-differs"
arm_rec "$DF"  "justified-not-derived" "vacuous-unconnected"
arm_rec "$DG"  "justified-not-derived" "vacuous-selfloop"
arm_rec "$DM"  "malformed-claim" "malformed-loud"
arm_rec "$DHF" "head-forgery" "head-forgery"
# the vacuous-differs record must name WHY it differs from the other two
# justified-not-derived arms: spine PRESENT and the differs guard PRESENT
sed -n "/^generation${TAB}$DE${TAB}/,/^record/p" "$WORK/out-arms" > "$WORK/block-e"
grep -q "spine${TAB}generation_config($DE,$SHAE,_)${TAB}PRESENT" "$WORK/block-e" || fail "VACUOUS-DIFFERS: the record does not show the spine PRESENT — $(cat "$WORK/block-e")"
grep -q "guard${TAB}landed_config($SHAE)${TAB}PRESENT" "$WORK/block-e" || fail "VACUOUS-DIFFERS: the differs guard is not PRESENT — $(cat "$WORK/block-e")"
grep -q "no-operator-row-cross-check-skipped" "$WORK/block-e" || fail "VACUOUS-DIFFERS: the unjournaled publish's cross-check skip is not STATED"
# ...and the unconnected/selfloop arms are guarded ABSENT (their defect is
# the argument, not the world)
sed -n "/^generation${TAB}$DF${TAB}/,/^record/p" "$WORK/out-arms" | grep -q "guard${TAB}landed_config($SHAE)${TAB}ABSENT" || fail "VACUOUS-UNCONNECTED: its guard should be ABSENT (the defect is the argument)"
# the stale-world finding names the binding that failed
grep -q "^finding${TAB}stale-world${TAB}$DC${TAB}" "$WORK/out-arms" || fail "STALE-WORLD: no named finding for $DC"
grep -q "from-version $VDB" "$WORK/out-arms" || fail "STALE-WORLD: the finding does not name the .operator from-version it disagrees with"
grep -q "^finding${TAB}malformed-claim${TAB}$DM${TAB}" "$WORK/out-arms" || fail "MALFORMED: no named finding for $DM"
ok "all nine arms answer by name (exit 1; derives control + 7 named refusals + claimless root)"

# ══ ROLLBACK: the round-2 BLOCKER — BINDING 3 joins on CONTENT ═════════════
echo "test_claim: ── the rollback store (a re-landed genhash is not a stale world) ──"

provision "$WORK/store-roll"
write_cfg_nc "$WORK/cfg-roll-root.dhall" roll-root
write_cfg_nc "$WORK/cfg-roll-mid.dhall" roll-mid

# the reviewer's measured sequence: root gen -> a later gen -> ROLLBACK
# re-activating the IDENTICAL root bytes (the same genhash lands AGAIN —
# the substrate adopts the existing dir) -> a new config whose HONEST claim
# names the root genhash (that IS the live world at the rollback version)
read VR1 GR < <(act "$WORK/cfg-roll-root.dhall")
SHAROOT=$(sha_of "$WORK/cfg-roll-root.dhall")
read VMID _GM < <(act "$WORK/cfg-roll-mid.dhall")
read VROLL GR2 < <(act "$WORK/cfg-roll-root.dhall")
[ "$GR2" = "$GR" ] || fail "ROLLBACK: re-activating the identical root config landed a DIFFERENT genhash ($GR2 != $GR) — the fixture is not a rollback"
[ "$VR1" -ne "$VROLL" ] || fail "ROLLBACK: the fixture no longer separates the two joins (the root's first appearance IS the rollback's from-version) — it cannot exercise the pre-fix first-appearance join; rebuild the fixture"
printf 'claima\tcfg-diff-roll\t%s\t%s\n' "$GR" "$SHAROOT" > "$WORK/rows/roll.tsv"
write_cfg "$WORK/cfg-roll-claim.dhall" roll-claim "$WORK/rows/roll.tsv" "$FIX/good.le"
read VC GC < <(act "$WORK/cfg-roll-claim.dhall")

write_operator "$WORK/store-roll"
oprow "$WORK/store-roll" 300 "$WORK/cfg-roll-root.dhall"  -      "$VR1"
oprow "$WORK/store-roll" 310 "$WORK/cfg-roll-mid.dhall"   "$VR1"  "$VMID"
oprow "$WORK/store-roll" 320 "$WORK/cfg-roll-root.dhall"  "$VMID" "$VROLL"
oprow "$WORK/store-roll" 330 "$WORK/cfg-roll-claim.dhall" "$VROLL" "$VC"

# the PIN: the PRE-FIX join's before, a fixed object cmp'd every run.  Its
# domain is the SCENARIO (the store symbols below are the fixture's own
# values, rebuilt live each run): the claim's from_version, its FIRST
# appearance, the op row's from-version, and the pre-fix join's WRONG
# answer on them.  It carries no judge output of the live seat.
{
    echo "binding3-before: the PRE-FIX BINDING 3 join (resolve_from_version + the version"
    echo "binding3-before: NUMBER comparison) on the rollback fixture:"
    echo "binding3-before:   the claim's from_version (genhash): $GR"
    echo "binding3-before:   its FIRST appearance (version):    $VR1"
    echo "binding3-before:   the op row's from-version:         $VROLL"
    echo "binding3-before:   $VR1 != $VROLL, so the pre-fix join answered stale-world on this"
    echo "binding3-before:   HONEST claim — it names the genhash live at version $VROLL (the"
    echo "binding3-before:   rollback re-landed it).  The fixed join is on CONTENT; the arm"
    echo "binding3-before:   asserts the claim DERIVES (the after, live below)."
} > "$WORK/rollpin-live.txt"
PINROLL="$FIX/rollback-join-before.txt"
[ -f "$PINROLL" ] || fail "ROLLBACK PIN: the pinned before is missing at $PINROLL"
cmp -s "$WORK/rollpin-live.txt" "$PINROLL" || fail "ROLLBACK PIN: the live pre-fix-join reconstruction is not the pinned before — the pin's domain moved; re-record it consciously. LIVE TEXT:
$(cat "$WORK/rollpin-live.txt")"
grep -q "^verdict" "$PINROLL" && fail "ROLLBACK PIN: the pin carries a judge verdict line — it would be pinning the AFTER as the before"

rc=$(run_claim "$WORK/out-roll" "$WORK/store-roll")
[ "$rc" = 0 ] || fail "ROLLBACK: the honest claim must derive after a rollback re-activation — exit 0 expected, got $rc ($(cat "$WORK/out-roll.err"))"
rec_of "$WORK/out-roll" "$GC" | grep -q "verdict=ok" || fail "ROLLBACK: the honest claim naming the re-landed root did not derive — $(rec_of "$WORK/out-roll" "$GC")"
if grep -q "^finding${TAB}stale-world" "$WORK/out-roll"; then fail "ROLLBACK: stale-world fired on an HONEST claim (the pre-fix first-appearance join is back)"; fi
ok "rollback: the honest claim naming the re-landed root derives (exit 0; the pre-fix join's before is pinned)"

# ══ SKIPPED: a refused/failed OUTCOME is stated, never judged ══════════════
echo "test_claim: ── the refused-outcome store (the skipped class) ──"

provision "$WORK/store-skip"
write_cfg_nc "$WORK/cfg-skip-root.dhall" skip-root
read SVR SGR < <(act "$WORK/cfg-skip-root.dhall")
SSHAROOT=$(sha_of "$WORK/cfg-skip-root.dhall")
printf 'claima\tcfg-diff-skip\t%s\t%s\n' "$SGR" "$SSHAROOT" > "$WORK/rows/skip.tsv"
write_cfg "$WORK/cfg-skip-claim.dhall" skip-claim "$WORK/rows/skip.tsv" "$FIX/good.le"
read SVC SGC < <(act "$WORK/cfg-skip-claim.dhall")

# the honest claim lands through a publish whose recorded OUTCOME is not ok
# (`dhake-failed` LANDED the generation — plan risk 6): there is a
# generation to judge and a claim in it, but NO judgment to run
write_operator "$WORK/store-skip"
oprow   "$WORK/store-skip" 400 "$WORK/cfg-skip-root.dhall"  -     "$SVR"
oprow_x "$WORK/store-skip" 410 "$WORK/cfg-skip-claim.dhall" "$SVR" "$SVC" dhake-failed

rc=$(run_claim "$WORK/out-skip" "$WORK/store-skip")
[ "$rc" = 0 ] || fail "SKIPPED: a refused-outcome publish is coherent (stated, not judged) — exit 0 expected, got $rc ($(cat "$WORK/out-skip.err"))"
rec_of "$WORK/out-skip" "$SGC" | grep -q "verdict=skipped" || fail "SKIPPED: the refused-outcome publish's claim must be verdict=skipped — $(rec_of "$WORK/out-skip" "$SGC")"
rec_of "$WORK/out-skip" "$SGC" | grep -q "note=operator-outcome-dhake-failed-no-disagreement" || fail "SKIPPED: the record does not name the refused outcome"
sed -n "/^generation${TAB}$SGC${TAB}/,/^record/p" "$WORK/out-skip" | grep -q "^eval${TAB}" && fail "SKIPPED: a skipped generation was JUDGED (an eval block ran) — the class says NO judgment"
if grep -q "^finding${TAB}stale-world" "$WORK/out-skip"; then fail "SKIPPED: the outcome gate must precede the bindings (no stale-world from an unjudged publish)"; fi
ok "skipped: the dhake-failed publish's claim is stated, not judged (exit 0, no eval block)"

# ══ RETRY: the round-3 BLOCKER — the outcome gate spans ALL landings ═══════
echo "test_claim: ── the retry store (a failed first landing, an ok re-landing of the SAME genhash) ──"

provision "$WORK/store-retry"
write_cfg_nc "$WORK/cfg-retry-root.dhall" retry-root
read RVR RGR < <(act "$WORK/cfg-retry-root.dhall")
RSHAROOT=$(sha_of "$WORK/cfg-retry-root.dhall")
printf 'claima\tcfg-diff-retry\t%s\t%s\n' "$RGR" "$RSHAROOT" > "$WORK/rows/retry.tsv"
write_cfg "$WORK/cfg-retry-claim.dhall" retry-claim "$WORK/rows/retry.tsv" "$FIX/good.le"
read RVC RGC < <(act "$WORK/cfg-retry-claim.dhall")
# the operator's retry: the SAME config re-activates — the substrate's
# adopt-if-exists re-lands the IDENTICAL bytes (the same genhash) at a new
# version, exactly as it does for a rollback
read RVC2 RGC2 < <(act "$WORK/cfg-retry-claim.dhall")
[ "$RGC2" = "$RGC" ] || fail "RETRY: re-activating the same claim config landed a DIFFERENT genhash ($RGC2 != $RGC) — the fixture is not a retry"
[ "$RVC" -ne "$RVC2" ] || fail "RETRY: the two landings share one version — the fixture cannot separate the first landing from the retry"

# the journal, the REAL writer's measured shapes: init.zig:3952 writes the
# failed landing's row with the LANDED version as to-version ('activation
# committed, live-root reapply failed'), :3965 the retry's ok row (from the
# first landing's version — the world the retry moved from).  Hand-written
# in the writer's shape and declared, like every .operator fixture here
# (fx-init does not run host-side).
write_operator "$WORK/store-retry"
oprow   "$WORK/store-retry" 600 "$WORK/cfg-retry-root.dhall"  -     "$RVR"
oprow_x "$WORK/store-retry" 610 "$WORK/cfg-retry-claim.dhall" "$RVR" "$RVC" dhake-failed
oprow   "$WORK/store-retry" 620 "$WORK/cfg-retry-claim.dhall" "$RVC" "$RVC2"

# the PIN: the PRE-FIX binding's before, a fixed object cmp'd every run
# against the LIVE reconstruction of the fixture's own values (the domain
# proof: the same genhash re-landed, the two landings separated, and the
# ok row's from-version being the claim's OWN first landing — the trap is
# real in this fixture).  It carries no judge output of the live seat.
{
    echo "retry-before: the PRE-FIX op-row binding (the FIRST landing's row alone"
    echo "retry-before: decides the outcome) on the retry fixture:"
    echo "retry-before:   the claim's genhash:          $RGC"
    echo "retry-before:   its FIRST landing (version):  $RVC"
    echo "retry-before:   the first landing's row:      dhake-failed (from $RVR)"
    echo "retry-before:   the ok re-landing (version):  $RVC2"
    echo "retry-before:   the ok row's from-version:    $RVC — the claim's OWN"
    echo "retry-before:   generation (the trap: binding 3 there false-fails)"
    echo "retry-before: the pre-fix binding answered verdict=skipped on exactly this"
    echo "retry-before: generation FOREVER — the live, ok-published one — zero eval"
    echo "retry-before: lines, exit 0, the seat never called.  The fixed rule spans"
    echo "retry-before: ALL landings; the arm asserts the claim IS judged (the"
    echo "retry-before: after, live below)."
} > "$WORK/retrypin-live.txt"
PINRETRY="$FIX/retry-skip-before.txt"
[ -f "$PINRETRY" ] || fail "RETRY PIN: the pinned before is missing at $PINRETRY"
cmp -s "$WORK/retrypin-live.txt" "$PINRETRY" || fail "RETRY PIN: the live pre-fix reconstruction is not the pinned before — the pin's domain moved; re-record it consciously. LIVE TEXT:
$(cat "$WORK/retrypin-live.txt")"
grep -q "^verdict" "$PINRETRY" && fail "RETRY PIN: the pin carries a judge verdict line — it would be pinning the AFTER as the before"

rc=$(run_claim "$WORK/out-retry" "$WORK/store-retry")
[ "$rc" = 0 ] || fail "RETRY: the failed-then-relanded-ok store is coherent — exit 0 expected, got $rc ($(cat "$WORK/out-retry.err"))"
rec_of "$WORK/out-retry" "$RGC" | grep -q "verdict=ok" || fail "RETRY: the live, ok-published generation's claim was never judged — $(rec_of "$WORK/out-retry" "$RGC")"
sed -n "/^generation${TAB}$RGC${TAB}/,/^record/p" "$WORK/out-retry" | grep -q "^eval${TAB}" || fail "RETRY: no eval block under the retried generation — the seat never called the evaluator"
if grep -q "^finding${TAB}stale-world" "$WORK/out-retry"; then fail "RETRY: stale-world fired — binding 3 rebound to the ok row's from-version (the measured trap) instead of the first landing's"; fi
ok "retry: the failed-then-relanded-ok generation's claim IS judged (verdict=ok, eval ran, no stale-world; the pre-fix binding's before is pinned)"

# ══ ROLLBACK-REC: the round-4 BLOCKER — the writer's ok ROLLBACK row lands ═
echo "test_claim: ── the rollback-recovery store (a generation published by fxctl rollback is judged) ──"

provision "$WORK/store-rbrec"
write_cfg_nc "$WORK/cfg-rbr-root.dhall" rbr-root
write_cfg_nc "$WORK/cfg-rbr-mid.dhall" rbr-mid

# the reviewer's measured sequence (round-4 review): root ok -> the claim
# generation lands behind a dhake-failed publish -> a later gen goes ok ->
# the operator's `fxctl rollback` returns to the CLAIM's version, which is
# the store's live CURRENT from then on.  The journal row is the writer's
# EXACT shape (init.zig:4056 — arg = the target operand, outcome ok, from =
# the current before, to = the current after fx_store_rollback_wrap: the
# RESULT version the soft rollback publishes (store.zig:1240), its snapshot
# naming the rolled-back-to genhash — NOT the target operand; this fixture
# passes the claim's own version, which row_lands measures identically;
# 7 fields, nonce tail) — hand-written and declared like every
# .operator fixture here (fxctl does not run host-side).  The store-side
# effect of the rollback (CURRENT moved to the target) is invisible to the
# seat, which reads the timeline, the per-version facts and this journal —
# never CURRENT — so the fixture needs no host-side rollback to exercise it.
read BRVR BRGR < <(act "$WORK/cfg-rbr-root.dhall")
BRSHAROOT=$(sha_of "$WORK/cfg-rbr-root.dhall")
printf 'claima\tcfg-diff-rbr\t%s\t%s\n' "$BRGR" "$BRSHAROOT" > "$WORK/rows/rbr.tsv"
write_cfg "$WORK/cfg-rbr-claim.dhall" rbr-claim "$WORK/rows/rbr.tsv" "$FIX/good.le"
read BRVC BRGC < <(act "$WORK/cfg-rbr-claim.dhall")
read BRVM _BRGM < <(act "$WORK/cfg-rbr-mid.dhall")

write_operator "$WORK/store-rbrec"
oprow    "$WORK/store-rbrec" 700 "$WORK/cfg-rbr-root.dhall"  -     "$BRVR"
oprow_x  "$WORK/store-rbrec" 710 "$WORK/cfg-rbr-claim.dhall" "$BRVR" "$BRVC" dhake-failed
oprow    "$WORK/store-rbrec" 720 "$WORK/cfg-rbr-mid.dhall"   "$BRVC" "$BRVM"
oprow_rb "$WORK/store-rbrec" 730 "$BRVC" "$BRVM" "$BRVC" ok

# the domain, proven live: the versions are separated, and the rollback's
# target (its to-version) IS the claim's first landing carrying its genhash
[ "$BRVR" -ne "$BRVC" ] && [ "$BRVC" -ne "$BRVM" ] || fail "ROLLBACK-REC: the fixture collapsed to one version — it cannot separate the landings"
LIVEG=$("$FXSTORE" facts generation --as-of "$BRVC" --store "$WORK/store-rbrec" | head -1 | cut -f1)
[ "$LIVEG" = "$BRGC" ] || fail "ROLLBACK-REC: the rollback's target version $BRVC does not carry the claim genhash in the timeline ($LIVEG != $BRGC) — the fixture is not a rollback-onto-the-claim"

# the PIN: the PRE-FIX filter's before, a fixed object cmp'd every run
# against the LIVE reconstruction of the fixture's own values (the domain
# proof above).  It carries no judge output of the live seat.
{
    echo "rollback-land-before: the PRE-FIX LANDING FILTER (the action=='activate' drop) on"
    echo "rollback-land-before: the rollback-recovery fixture:"
    echo "rollback-land-before:   the claim's genhash:            $BRGC"
    echo "rollback-land-before:   its FIRST landing (version):    $BRVC — activate, dhake-failed, from $BRVR"
    echo "rollback-land-before:   the mid generation (version):   $BRVM"
    echo "rollback-land-before:   the ok ROLLBACK row (the writer's shape, init.zig:4056):"
    echo "rollback-land-before:     rollback $BRVC ok $BRVM $BRVC gatenonce"
    echo "rollback-land-before: the pre-fix filter dropped every non-activate row, so the"
    echo "rollback-land-before: only rows naming the claim genhash carried dhake-failed —"
    echo "rollback-land-before: the LIVE generation (its landing IS the rollback) answered"
    echo "rollback-land-before: skipped FOREVER: zero eval lines, exit 0, the seat never"
    echo "rollback-land-before: called.  The fixed filter reads the writer's terminal"
    echo "rollback-land-before: rollback rows; the arm asserts the claim IS judged (the"
    echo "rollback-land-before: after, live below)."
} > "$WORK/rbrecpin-live.txt"
PINRB="$FIX/rollback-land-before.txt"
[ -f "$PINRB" ] || fail "ROLLBACK-REC PIN: the pinned before is missing at $PINRB"
cmp -s "$WORK/rbrecpin-live.txt" "$PINRB" || fail "ROLLBACK-REC PIN: the live pre-fix reconstruction is not the pinned before — the pin's domain moved; re-record it consciously. LIVE TEXT:
$(cat "$WORK/rbrecpin-live.txt")"
grep -q "^verdict" "$PINRB" && fail "ROLLBACK-REC PIN: the pin carries a judge verdict line — it would be pinning the AFTER as the before"

rc=$(run_claim "$WORK/out-rbrec" "$WORK/store-rbrec")
[ "$rc" = 0 ] || fail "ROLLBACK-REC: the rollback-published store is coherent — exit 0 expected, got $rc ($(cat "$WORK/out-rbrec.err"))"
rec_of "$WORK/out-rbrec" "$BRGC" | grep -q "verdict=ok" || fail "ROLLBACK-REC: the live generation's claim was never judged (the round-4 blocker) — $(rec_of "$WORK/out-rbrec" "$BRGC")"
sed -n "/^generation${TAB}$BRGC${TAB}/,/^record/p" "$WORK/out-rbrec" | grep -q "^eval${TAB}" || fail "ROLLBACK-REC: no eval block under the rollback-published generation — the seat never called the evaluator"
# the trap, one arm further: op-from must be the FIRST landing's ACTIVATE
# row (the dhake-failed row's from = the root), NEVER the rollback row's
# from-version (the mid gen — the world the rollback moved FROM)
rec_of "$WORK/out-rbrec" "$BRGC" | grep -q "op-from=$BRVR" || fail "ROLLBACK-REC: op-from is not the first landing's from-version ($BRVR) — binding 3 rebound to the rollback row's from-world ($(rec_of "$WORK/out-rbrec" "$BRGC"))"
if grep -q "^finding${TAB}stale-world" "$WORK/out-rbrec"; then fail "ROLLBACK-REC: stale-world fired — binding 3 bound the rollback row's from-version instead of the first landing's"; fi
ok "rollback-rec: the generation published by the ok rollback IS judged (verdict=ok, eval ran, op-from binds the first landing's activate row; the pre-fix filter's before is pinned)"

# ══ CAP: the round-4 SHOULD-FIX — a journal past MAX_OP_ROWS dies loudly ══
echo "test_claim: ── the capped journal (the tail is where the re-landings live) ──"

provision "$WORK/store-cap"
write_cfg_nc "$WORK/cfg-cap-root.dhall" cap-root
read CVR CGR < <(act "$WORK/cfg-cap-root.dhall")
CSHAROOT=$(sha_of "$WORK/cfg-cap-root.dhall")
printf 'claima\tcfg-diff-cap\t%s\t%s\n' "$CGR" "$CSHAROOT" > "$WORK/rows/cap.tsv"
write_cfg "$WORK/cfg-cap-claim.dhall" cap-claim "$WORK/rows/cap.tsv" "$FIX/good.le"
read CVC CGC < <(act "$WORK/cfg-cap-claim.dhall")
read CVC2 CGC2 < <(act "$WORK/cfg-cap-claim.dhall")
[ "$CGC2" = "$CGC" ] || fail "CAP: re-activating the same claim config landed a DIFFERENT genhash ($CGC2 != $CGC) — the fixture is not a retry"
[ "$CVC" -ne "$CVC2" ] || fail "CAP: the two landings share one version — the fixture cannot put the ok row past the cap"

# the reviewer's measured resurrection (round-4 review): 4094 fillers push
# the ok retry row past MAX_OP_ROWS.  The fillers are the writer's OWN
# failed:<rc> rows (init.zig:3801 — outcome failed:<rc>, to '-': the child
# failed and whether it moved the store is not known from here) — they parse
# and land nothing, exactly as a long-lived machine accumulates them.
write_operator "$WORK/store-cap"
python3 - "$WORK/store-cap/.operator" "$CVR" <<'PYEOF'
import sys
path, cvr = sys.argv[1], sys.argv[2]
with open(path, "a") as f:
    for i in range(4094):
        f.write("%d activate /filler/%d.dhall failed:1 %s - gatenonce\n" % (5000 + i, i, cvr))
PYEOF
oprow   "$WORK/store-cap" 9000 "$WORK/cfg-cap-root.dhall"  -     "$CVR"
oprow_x "$WORK/store-cap" 9010 "$WORK/cfg-cap-claim.dhall" "$CVR" "$CVC" dhake-failed
oprow   "$WORK/store-cap" 9020 "$WORK/cfg-cap-claim.dhall" "$CVC" "$CVC2"

# the FIXED seat dies loudly, naming the cap and why the tail matters
"$CLAIM" --store "$WORK/store-cap" --policy "$POLICY" --fxstore "$FXSTORE" \
    --obs-dir "$WORK/obs-cap" >"$WORK/out-cap" 2>"$WORK/out-cap.err"
rc=$?
[ "$rc" = 2 ] || fail "CAP: the seat must DIE LOUDLY on a journal past the cap (exit 2), got $rc ($(cat "$WORK/out-cap.err"))"
grep -q "more than 4096 rows" "$WORK/out-cap.err" || fail "CAP: the die does not name the cap it hit — $(cat "$WORK/out-cap.err")"
grep -q "live at the tail" "$WORK/out-cap.err" || fail "CAP: the die does not say why the tail matters (the re-landings live there)"
ok "cap: a journal past MAX_OP_ROWS dies loudly, naming the cap and the tail (exit 2; the pre-fix silent drop is M7's fixture, below)"

# ══ MUTANTS: each blind on exactly its own fixture ════════════════════════
echo "test_claim: ── the mutants (each blind on exactly its own fixture) ──"

MUTCFLAGS="-std=c11 -O2 -Wall -Isrc/vendor/dhall-c -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE"
build_seat() { # build_seat OUT SRCFILE
    cc $MUTCFLAGS -o "$1" "$2" src/vendor/dhall-c/sha256.c || fail "cannot build the mutant seat $1"
}

# the exit-code discipline: capture rc=$? IMMEDIATELY after the run, never
# through a pipe or an intervening echo (the pipe's status is not the run's)
arm_rec_out() { # arm_rec_out OUTFILE GENHASH WANTCLASS LABEL
    grep "^record${TAB}$2${TAB}" "$1" | grep -q "verdict=$3" || fail "$4: expected verdict=$3 — $(grep "^record${TAB}$2${TAB}" "$1")"
}

# M1: the POLICY mutant drops the differs guard (an unpinned copy: the pin
# exists to catch an UNDECLARED policy change, and this one is declared)
rm -rf "$WORK/pol1"; cp -r policy "$WORK/pol1" || fail "copy policy"
rm -f "$WORK/pol1/PINS"
sed -e 's/, !landed_config(C2)//' "$POLICY" > "$WORK/pol1/claims-policy.dl"
cmp -s "$POLICY" "$WORK/pol1/claims-policy.dl" && fail "M1: the policy sed matched NOTHING (the mutant would be the original)"
grep -q "landed_config" "$WORK/pol1/claims-policy.dl" && fail "M1: the guard atom survived the drop"
rc=$(run_claim "$WORK/out-m1" "$WORK/store-arms" --policy "$WORK/pol1/claims-policy.dl" --obs-dir "$WORK/obs-m1")
[ "$rc" = 1 ] || fail "M1: the arms store still carries refusals, got $rc"
arm_rec_out "$WORK/out-m1" "$DE" "ok" "M1-guard-dropped-vacuous-differs"
grep -q "^eval${TAB}verdict${TAB}derives" "$WORK/out-m1" || fail "M1: the vacuous-differs generation did not DERIVE under the guard-dropped policy"
arm_rec_out "$WORK/out-m1" "$DB" "ok" "M1-honest-control-unchanged"
arm_rec_out "$WORK/out-m1" "$DF" "justified-not-derived" "M1-unconnected-unchanged"
arm_rec_out "$WORK/out-m1" "$DC" "stale-world" "M1-stale-world-unchanged"
ok "M1 guard-drop: vacuous-differs flips to derives; honest/unconnected/stale-world unchanged"

# M2: the SEAT mutant deletes the one binding3 call line
sed '/binding3_opfrom(G, row_ok/d' tools/fx-claim.c > "$WORK/mut2.c"
cmp -s tools/fx-claim.c "$WORK/mut2.c" && fail "M2: the seat sed matched NOTHING (the mutant would be the original)"
grep -q "static void binding3_opfrom" "$WORK/mut2.c" || fail "M2: the sed deleted more than the call (the definition is gone)"
build_seat "$WORK/mut2" "$WORK/mut2.c"
"$WORK/mut2" --store "$WORK/store-arms" --policy "$POLICY" --fxstore "$FXSTORE" \
    --obs-dir "$WORK/obs-m2" >"$WORK/out-m2" 2>"$WORK/out-m2.err"
rc=$?
[ "$rc" = 1 ] || fail "M2: expected exit 1 (other refusals remain), got $rc"
arm_rec_out "$WORK/out-m2" "$DC" "ok" "M2-stale-world-flips"
grep -q "^eval${TAB}verdict${TAB}derives" "$WORK/out-m2" || fail "M2: the stale-world claim did not reach the evaluator under the mutant"
arm_rec_out "$WORK/out-m2" "$DB" "ok" "M2-honest-control-unchanged"
arm_rec_out "$WORK/out-m2" "$DD" "premise-false" "M2-premise-false-unchanged"
ok "M2 binding3-drop: stale-world flips to the evaluator's derives; honest/premise-false unchanged"

# M3: the SEAT mutant replaces the enrollment boundary — every run enrolls
sed -e 's/int enroll = !g_have_obs || g_reenroll;/int enroll = 1;/' \
    tools/fx-claim.c > "$WORK/mut3.c"
cmp -s tools/fx-claim.c "$WORK/mut3.c" && fail "M3: the seat sed matched NOTHING (the mutant would be the original)"
grep -q "int enroll = 1;" "$WORK/mut3.c" || fail "M3: the boundary was not replaced"
build_seat "$WORK/mut3" "$WORK/mut3.c"
# the honest pair: a claimless root enrolls fine; a claimless NEW generation
# post-enrollment is the finding
for kind in honest mutant; do
    S="$WORK/store-m3-$kind"; provision "$S"
    write_cfg_nc "$WORK/cfg-m3a.dhall" "m3a-$kind"
    read _V1 _G1 < <(act "$WORK/cfg-m3a.dhall")
    if [ "$kind" = honest ]; then SEAT="$CLAIM"; else SEAT="$WORK/mut3"; fi
    "$SEAT" --store "$S" --policy "$POLICY" --fxstore "$FXSTORE" >"$WORK/out-m3-$kind-1" 2>&1
    rc=$?
    [ "$rc" = 0 ] || fail "M3-$kind: the enrollment run (claimless root) must exit 0, got $rc"
    write_cfg_nc "$WORK/cfg-m3b.dhall" "m3b-$kind"
    read _V2 _G2 < <(act "$WORK/cfg-m3b.dhall")
    "$SEAT" --store "$S" --policy "$POLICY" --fxstore "$FXSTORE" >"$WORK/out-m3-$kind-2" 2>&1
    rc=$?
    if [ "$kind" = honest ]; then
        [ "$rc" = 1 ] || fail "M3-honest: the claimless generation post-enrollment must exit 1, got $rc"
        grep -q "^finding${TAB}no-claim${TAB}$_G2${TAB}" "$WORK/out-m3-honest-2" || fail "M3-honest: no no-claim finding for the new generation"
    else
        [ "$rc" = 0 ] || fail "M3-mutant: with the boundary dropped the claimless generation reads none-occurred (exit 0 expected), got $rc"
        grep -q "verdict=claimless" "$WORK/out-m3-mutant-2" || fail "M3-mutant: the claimless generation was not read none-occurred"
        if grep -q "^finding${TAB}no-claim" "$WORK/out-m3-mutant-2"; then fail "M3-mutant: the boundary-dropped seat still fired no-claim"; fi
    fi
done
ok "M3 enrollment-boundary drop: the claimless generation reads none-occurred (the §1a gap-3 error, executed)"

# M4: the EVALUATOR mutant drops the head check (the S0 A6 sed) — the pin
# does not cover eval_claim.py, so the copied dir keeps its PINS
rm -rf "$WORK/pol4"; cp -r policy "$WORK/pol4" || fail "copy policy"
sed -e 's@if pred not in AGENT_CONCLUSIONS:@if False:@' policy/eval_claim.py > "$WORK/pol4/eval_claim.py"
cmp -s policy/eval_claim.py "$WORK/pol4/eval_claim.py" && fail "M4: the evaluator sed matched NOTHING (the mutant would be the original)"
"$CLAIM" --store "$WORK/store-arms" --policy "$WORK/pol4/claims-policy.dl" --fxstore "$FXSTORE" \
    --obs-dir "$WORK/obs-m4" >"$WORK/out-m4" 2>"$WORK/out-m4.err"
rc=$?
[ "$rc" = 1 ] || fail "M4: expected exit 1 (other refusals remain), got $rc"
arm_rec_out "$WORK/out-m4" "$DHF" "ok" "M4-head-forgery-flips"
arm_rec_out "$WORK/out-m4" "$DB" "ok" "M4-honest-control-unchanged"
arm_rec_out "$WORK/out-m4" "$DC" "stale-world" "M4-stale-world-unchanged"
ok "M4 head-check drop: head-forgery flips to derives; honest/stale-world unchanged"

# M5: the SEAT mutant restores the ROUND-2 op-row binding (the FIRST
# landing's row alone decides the outcome) — the round-3 blocker, executed
sed -e 's/if (!row_lands(g_op\[r\].tov, G)) continue;/if (strcmp(g_op[r].tov, first_tov)) continue;/' \
    tools/fx-claim.c > "$WORK/mut5.c"
cmp -s tools/fx-claim.c "$WORK/mut5.c" && fail "M5: the seat sed matched NOTHING (the mutant would be the original)"
grep -q "static int row_lands" "$WORK/mut5.c" || fail "M5: the sed replaced more than the one binding line (the helper's definition is gone)"
build_seat "$WORK/mut5" "$WORK/mut5.c"
"$WORK/mut5" --store "$WORK/store-retry" --policy "$POLICY" --fxstore "$FXSTORE" \
    --obs-dir "$WORK/obs-m5" >"$WORK/out-m5" 2>"$WORK/out-m5.err"
rc=$?
[ "$rc" = 0 ] || fail "M5: the skipped-only retry store is coherent under the pre-fix binding too (exit 0 expected), got $rc"
arm_rec_out "$WORK/out-m5" "$RGC" "skipped" "M5-first-landing-binding-skips-the-retry"
sed -n "/^generation${TAB}$RGC${TAB}/,/^record/p" "$WORK/out-m5" | grep -q "^eval${TAB}" && fail "M5: the pre-fix binding JUDGED the retried generation — the mutant is not the pre-fix behavior"
# the single-landing SKIPPED arm is UNCHANGED under M5 (the skipped class
# survives the round-3 rule for its own case), and so is the ROLLBACK arm's
# honest claim (the mutant is blind on exactly the retry fixture)
"$WORK/mut5" --store "$WORK/store-skip" --policy "$POLICY" --fxstore "$FXSTORE" \
    --obs-dir "$WORK/obs-m5b" >"$WORK/out-m5-skip" 2>"$WORK/out-m5-skip.err"
rc=$?
[ "$rc" = 0 ] || fail "M5: the single-landing skip store must stay coherent, got $rc"
arm_rec_out "$WORK/out-m5-skip" "$SGC" "skipped" "M5-single-landing-skip-unchanged"
"$WORK/mut5" --store "$WORK/store-roll" --policy "$POLICY" --fxstore "$FXSTORE" \
    --obs-dir "$WORK/obs-m5c" >"$WORK/out-m5-roll" 2>"$WORK/out-m5-roll.err"
rc=$?
[ "$rc" = 0 ] || fail "M5: the rollback store must stay coherent, got $rc"
arm_rec_out "$WORK/out-m5-roll" "$GC" "ok" "M5-rollback-honest-unchanged"
ok "M5 first-landing-binding restore: the retry arm's claim is skipped again (the pre-fix seat, executed); skip/rollback arms unchanged"

# M6: the SEAT mutant restores the ROUND-3 landing filter (ACTIVATE rows
# only — the one line the round-4 fix widened) — the round-4 blocker,
# executed
sed -e 's/if (!is_act \&\& strcmp(g_op\[r\].action, "rollback")) continue;/if (strcmp(g_op[r].action, "activate")) continue;/' \
    tools/fx-claim.c > "$WORK/mut6.c"
cmp -s tools/fx-claim.c "$WORK/mut6.c" && fail "M6: the seat sed matched NOTHING (the mutant would be the original)"
grep -q "static int row_lands" "$WORK/mut6.c" || fail "M6: the sed replaced more than the one filter line (the helper's neighborhood is gone)"
build_seat "$WORK/mut6" "$WORK/mut6.c"
"$WORK/mut6" --store "$WORK/store-rbrec" --policy "$POLICY" --fxstore "$FXSTORE" \
    --obs-dir "$WORK/obs-m6" >"$WORK/out-m6" 2>"$WORK/out-m6.err"
rc=$?
[ "$rc" = 0 ] || fail "M6: the rollback-recovery store is coherent under the pre-fix filter too (exit 0 expected), got $rc"
arm_rec_out "$WORK/out-m6" "$BRGC" "skipped" "M6-activate-only-filter-skips-the-rollback"
sed -n "/^generation${TAB}$BRGC${TAB}/,/^record/p" "$WORK/out-m6" | grep -q "^eval${TAB}" && fail "M6: the pre-fix filter JUDGED the rollback-published generation — the mutant is not the pre-fix behavior"
# the mutant is blind on exactly the rollback-recovery fixture: the RETRY
# arm (an ok ACTIVATE re-landing), the single-landing SKIPPED arm and the
# ROLLBACK arm's honest claim keep their answers (every journal there is
# activate-only)
"$WORK/mut6" --store "$WORK/store-retry" --policy "$POLICY" --fxstore "$FXSTORE" \
    --obs-dir "$WORK/obs-m6b" >"$WORK/out-m6-retry" 2>"$WORK/out-m6-retry.err"
rc=$?
[ "$rc" = 0 ] || fail "M6: the retry store must stay coherent, got $rc"
arm_rec_out "$WORK/out-m6-retry" "$RGC" "ok" "M6-retry-unchanged"
"$WORK/mut6" --store "$WORK/store-skip" --policy "$POLICY" --fxstore "$FXSTORE" \
    --obs-dir "$WORK/obs-m6c" >"$WORK/out-m6-skip" 2>"$WORK/out-m6-skip.err"
rc=$?
[ "$rc" = 0 ] || fail "M6: the single-landing skip store must stay coherent, got $rc"
arm_rec_out "$WORK/out-m6-skip" "$SGC" "skipped" "M6-single-landing-skip-unchanged"
"$WORK/mut6" --store "$WORK/store-roll" --policy "$POLICY" --fxstore "$FXSTORE" \
    --obs-dir "$WORK/obs-m6d" >"$WORK/out-m6-roll" 2>"$WORK/out-m6-roll.err"
rc=$?
[ "$rc" = 0 ] || fail "M6: the rollback store must stay coherent, got $rc"
arm_rec_out "$WORK/out-m6-roll" "$GC" "ok" "M6-rollback-honest-unchanged"
ok "M6 activate-only-filter restore: the rollback-published generation is skipped again (the pre-fix seat, executed); retry/skip/rollback arms unchanged"

# M7: the SEAT mutant restores the SILENT tail-drop at MAX_OP_ROWS (the old
# loop condition — exactly the one behaviour the round-4 fix changed) — the
# should-fix's silent failure mode, executed on the CAP arm's store
sed -e 's/for (char \*tok = strtok_r(bytes, "\\n", &save); tok;/for (char *tok = strtok_r(bytes, "\\n", \&save); tok \&\& g_nop < MAX_OP_ROWS;/' \
    tools/fx-claim.c > "$WORK/mut7.c"
cmp -s tools/fx-claim.c "$WORK/mut7.c" && fail "M7: the seat sed matched NOTHING (the mutant would be the original)"
grep -q 'tok && g_nop < MAX_OP_ROWS' "$WORK/mut7.c" || fail "M7: the silent-truncation condition was not restored"
build_seat "$WORK/mut7" "$WORK/mut7.c"
"$WORK/mut7" --store "$WORK/store-cap" --policy "$POLICY" --fxstore "$FXSTORE" \
    --obs-dir "$WORK/obs-m7" >"$WORK/out-m7" 2>"$WORK/out-m7.err"
rc=$?
[ "$rc" = 0 ] || fail "M7: the capped store answers coherently under the silent drop too (exit 0 expected), got $rc"
arm_rec_out "$WORK/out-m7" "$CGC" "skipped" "M7-silent-tail-drop-skips-the-live-generation"
sed -n "/^generation${TAB}$CGC${TAB}/,/^record/p" "$WORK/out-m7" | grep -q "^eval${TAB}" && fail "M7: the resurrected skip JUDGED the generation — the mutant is not the pre-fix behavior"
ok "M7 silent tail-drop restore: the ok retry row past the cap vanishes and the live generation is skipped again, zero eval lines (the should-fix's failure mode, executed)"

# M8: the SEAT mutant deletes the round-5 UNJOURNALED-LANDINGS bound line
# (the one printf) — the bound must PRINT on every run and can be MISSING:
# the arm proves both, executing the decoration's failure mode
sed '/printf("bound\\tunjournaled-landings/d' tools/fx-claim.c > "$WORK/mut8.c"
cmp -s tools/fx-claim.c "$WORK/mut8.c" && fail "M8: the seat sed matched NOTHING (the mutant would be the original)"
build_seat "$WORK/mut8" "$WORK/mut8.c"
"$WORK/mut8" --store "$WORK/store-rbrec" --policy "$POLICY" --fxstore "$FXSTORE" \
    --obs-dir "$WORK/obs-m8" >"$WORK/out-m8" 2>"$WORK/out-m8.err"
rc=$?
[ "$rc" = 0 ] || fail "M8: the bound-deleted seat answers the store identically apart from the line (exit 0 expected), got $rc ($(cat "$WORK/out-m8.err"))"
if grep -q "^bound${TAB}unjournaled-landings" "$WORK/out-m8"; then fail "M8: the bound-line-deleted mutant still PRINTS the bound — the arm cannot see the mutation (the bound is decoration)"; fi
arm_rec_out "$WORK/out-m8" "$BRGC" "ok" "M8-bound-deleted-judgment-unchanged"
# the FIXED seat prints it on every run — asserted on the rollback-rec run above
grep -q "^bound${TAB}unjournaled-landings" "$WORK/out-rbrec" || fail "the fixed seat does not print the round-5 unjournaled-landings bound — see the header's DECISION B statement"
ok "M8 bound-line deletion: the unjournaled-landings bound is absent under the mutant and present on every fixed run, judgments identical (the bound is not decoration)"

# ══ PIN: the pre-fix control — the prose-reader accepting the vacuous claim ═
echo "test_claim: ── the pinned pre-fix control (the prose-reader's before) ──"
row=$(cat "$FIX/good.tsv")
sfrom=$(printf '%s' "$row" | cut -f4)
{
    echo "prose-reader: reading the claim as text — the pre-fix world takes the claim's word"
    echo "prose-reader: claim row: $row"
    echo "prose-reader: with the landed config equal to s_from ($sfrom), this is the vacuous-differs claim (S0 a4c)"
    echo "prose-reader: ACCEPTED — well-formed prose asserting a diff; nothing checked it (the before)"
} > "$WORK/prose-live.txt"
PIN="$FIX/prose-reader-before.txt"
[ -f "$PIN" ] || fail "PIN: the pinned before is missing at $PIN"
cmp -s "$WORK/prose-live.txt" "$PIN" || fail "PIN: the live prose-read of the fixture is not the pinned before — the pin's domain moved; re-record it consciously"
grep -qF "$row" "$PIN" || fail "PIN: the pin does not carry the claim row's raw bytes (it must pin the PROSE surface)"
if grep -q "^verdict" "$PIN"; then fail "PIN: the pin carries a judge verdict line — it would be pinning the AFTER as the before"; fi
# the after, same claim shape, is the ARMS store's vacuous-differs refusal (armed above)
grep -q "verdict=justified-not-derived" "$WORK/out-arms" || fail "PIN: the after (the judge's refusal) is not armed"
ok "pre-fix control: the prose-reader ACCEPTS (pinned, cmp, domain-proofed) what the judge refuses"

# ── the stated bounds, on every run ───────────────────────────────────────
echo "test_claim: BOUND: the judge and its evaluator run HOST-SIDE — a deployment stopgap, labelled: same lexicon, same policy, same claim bytes, same record; the committed target is in-guest (qemu lane, x64 via QBE)"
echo "test_claim: BOUND: the fixture rows carry real store symbols only in the ROW (from_version/S_from are engine symbols from the TSV); the .le arguments never spell a hash (le proper nouns are letters-only)"
echo "test_claim: BOUND: a no-op activation adds a VERSION but no GENERATION (content-addressed): the seat judges generations — the reporter (S2) owns the version-plane view"
echo "test_claim: BOUND: .operator is fx-init's file and fx-init does not run host-side: the gate wrote it in the writer's exact shape and declares it; the vacuous-differs activation deliberately carries NO row (unjournaled publish), and the seat states the skip"
echo "test_claim: BOUND: MEASURED, structural: an extraEtc claim row can never name ITS OWN generation's landed config (S_from would be the sha256 of the bytes carrying it — a preimage of its own container), so the vacuous-differs fixture's rows are hand-placed into the retained generation dir in the claim's exact format, declared; every other arm rides in via extraEtc"
echo "test_claim: BOUND: BINDINGS 1/2 canonicalize a generation to its FIRST-appearance version: a comment-only re-activation keeps the genhash and re-asserts generation_config with the newer bytes' sha — the later sha is invisible; the seat judges the bytes the claim rode in against (version=N on the record line)"
echo "test_claim: BOUND: the round-3 first-match SWEEP — every first-appearance/first-row assumption in the seat is either FIXED (the op-row binding: the outcome now spans ALL landings of a genhash) or MEASURED-EXACT on real stores: one generation row per version and one generation_config row per genhash per snapshot (activate.zig clears then adds exactly one — its own comment: 'exactly one row describes the live generation'); one terminal .operator row per activation (init.zig: refused-config/dhake-failed/unverified/ok, each naming the LANDED version; each publish a fresh version); the first tsv line feeds only the seat's bindings while the evaluator REFUSES a multi-row claim file by name; resolve_from_version's first-appearance dump choice is content-identical across re-landings (measured, round-2 review probes 2/3). Multiplicity beyond these is a hand-tampered artifact — inside the stated host-trust bound"

echo "test_claim: BOUND: the round-4 LANDING SET — the OUTCOME gate reads the writer's terminal .operator rows BY NAME: activate rows, and rollback rows that name their landed target (init.zig:4013/:4056 — refused-config and ok; refused/unverified rollbacks and every shutdown row carry to='-' and land nothing).  A FUTURE writer action that lands versions must be added to the filter BY NAME or its landings are dropped — the round-4 blocker's class, stated (direction: a silent never-judged generation); and the OUTCOME vocabulary is read BY NAME too (strcmp \"ok\"): a FUTURE outcome name meaning 'landed fine' silently counts not-ok — the same residual, sibling cell\n"
echo "test_claim: BOUND: the round-5 UNJOURNALED LANDINGS — the seat judges a generation from its <store>/.operator rows ALONE (JOURNALED landings); the writer's own header (operator_journal.zig:174-183) enumerates landing moves that write NO row there and are NOT read BY DESIGN (DECISION B): the AUTOMATIC .recovery roll-forward (init.zig:1798 — a flapping machine rolls FORWARD to the newest ok-booted version via the SAME soft rollback, the row lands in .recovery ONLY, which the AUDIT reads and which means AUTOMATIC — the seat does NOT read it), a host-side fxstore rollback, rollback --hard, and a hand-edited CURRENT.  DIRECTION: a claim generation first landed with a non-ok outcome and later RE-LANDED by one of these stays verdict=skipped while live and ok-booted — its claim is never judged, silently.  The bound PRINTS as a bound<TAB>unjournaled-landings line on every run (fx-report's idiom); M8 executes its removal\n"
echo "test_claim: ALL ARMS GREEN"
