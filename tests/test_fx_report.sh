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
#   ABSENT      the none-vs-not-recorded distinction, both directions:
#              S3 (never booted) says `absence .bootlog
#              no-boot-ever-recorded` and emits NO boot event; the rt-log
#              absence says NOT-durably-recorded (tmpfs) and the taxonomy's
#              activation-refusal row says the same — "no refusals
#              occurred" CANNOT be concluded.  FAIL: an absence printed as
#              a zero, or a not-recorded printed as none.
#   FOREIGN     a .bootlog line naming a version not in the timeline is
#              reported with the pruned-or-foreign note (the
#              pre-first-snapshot bound, visible in-band).  FAIL: dropped.
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
#   LOUD        an over-long .bootlog is exit 2 NAMING the cap (a report
#              over a truncated view is a lie); an unreadable .bootlog is
#              exit 2 (a read error is not an absence).  FAIL: exit 0.
#   MUTATIONS   each sed-mutated copy of the seat, with ONE taxonomy piece
#              disabled, must make its own arm's assertion go blind:
#              MUT-CLASS (the operator-intervention emission tag) ->
#              OPERATOR arm fails on the mutant; MUT-ATTRIB (delete the
#              .recovery attribution line) -> the AUTO control fails on
#              the mutant; MUT-FINDING (the copy-gone finding tag) -> the
#              FINDINGS arm fails on the mutant.  A taxonomy nobody can
#              falsify is decoration.
#   PINS        nothing depends on the position of HEAD: the citations in
#              the tool's frozen retention table are pinned to FIXED
#              revisions (fx-init 4c5803d, fxstore 0341650 — the trees the
#              table was measured against), guarded by git cat-file -e and
#              cmp-proven EQUAL to the working tree, so a moved sibling
#              fails the gate LOUDLY instead of leaving the table citing
#              line numbers that no longer exist.
#
# FIXTURE HONESTY: .bootlog/.recovery are fx-init's files and fx-init does
# not run host-side; the gate writes them in the writers' exact formats
# (bootlog_append's "%u %s %u %s\n" — in-progress at boot start plus the
# verdict per boot; recovery's "#"-header + "<epoch> <published>
# <from-failed> <genhash|-> <nonce>" row) and DECLARES that here, exactly
# as tests/test_fx_audit.sh does.  Everything else is written by the real
# writers: fx-activate (host-built, the audit gate's provisioning shape)
# and fxstore itself (the soft rollback fx-init's roll-forward drives
# in-guest).
#
# Env: FXSTORE_BIN (default ../fxstore/zig-out/bin/fxstore), FX_INIT_REPO,
#      FX_REPORT_KEEP=1.
set -u

fail() { echo "test_fx_report: FAIL: $*" >&2; exit 1; }
skip() { echo "test_fx_report: SKIP ($*)"; exit 77; }

cd "$(dirname "$0")/.." || fail "cannot cd to repo root"
REPO="$PWD"
SIBS="$(cd "$REPO/.." && pwd)"

command -v cc >/dev/null 2>&1 || skip "cc not found"
command -v sed >/dev/null 2>&1 || skip "sed not found"

FXSTORE="${FXSTORE_BIN:-$SIBS/fxstore/zig-out/bin/fxstore}"
[ -x "$FXSTORE" ] || skip "fxstore binary missing at $FXSTORE (build the sibling)"
"$FXSTORE" --help 2>&1 | grep -q 'fxstore facts' || skip "fxstore at $FXSTORE predates 'facts' (rebuild the sibling)"
grep -aq generation_config "$FXSTORE" || skip "fxstore at $FXSTORE predates the generation_config schema row (rebuild the sibling)"
grep -aq "keeping generation dir" "$FXSTORE" \
    || skip "fxstore at $FXSTORE predates the gc generation-dir carve-out (rebuild the sibling)"

INIT="${FX_INIT_REPO:-$SIBS/fx-init}"
[ -d "$INIT" ] || skip "fx-init checkout not found at $INIT (set FX_INIT_REPO)"
DL="$SIBS/datalog-dafsa/zig-out/lib"
[ -f "$DL/libdatalog.so" ] || skip "libdatalog.so missing at $DL"

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
grep -aq "CANNOT be concluded from any durable record" "$REPORT" \
    || fail "STALE BINARY: $REPORT does not contain this source's refusal-taxonomy row"

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
pin_guard "$INIT" 4c5803d zig/src/init.zig "fx-init"
pin_guard "$FXS_REPO" 0341650 zig/src/provenance.zig "fxstore"
pin_blob "$FXS_REPO" 30dce7cbb60105348d2ba44fa11d224487351af9 zig/src/store.zig "fxstore"

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
# automatic roll-forward drives in-guest, init.zig:3550) republishes VA's
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

# ══ MUTATIONS: disable one taxonomy piece at a time; the arm that asserts
#    it must GO BLIND on the mutant, or the taxonomy is decoration ══════
mutbuild() { # mutbuild NAME SED-EXPR -> builds build/fx-report-<name>
    cp "$REPO/tools/fx-report.c" "$WORK/mut-$1.c"
    sed "$2" "$WORK/mut-$1.c" > "$WORK/mut-$1.c.new" && mv "$WORK/mut-$1.c.new" "$WORK/mut-$1.c"
    cc -std=c11 -O2 -g -Wall -Wextra -Isrc/vendor/dhall-c -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE \
        -o "$REPO/build/fx-report-$1" "$WORK/mut-$1.c" src/vendor/dhall-c/sha256.c \
        || fail "MUTATION $1: the mutated source does not build"
}

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

# the mutants are gate artifacts, not seats — remove them so no stale
# binary can later answer for the seat
rm -f "$REPO/build/fx-report-class" "$REPO/build/fx-report-attrib" "$REPO/build/fx-report-finding"

echo "test_fx_report: PASS — the reconstruction is answerable from the report alone (both inputs readable, the diff, the generation each produced), the taxonomy separates none-occurred from not-durably-recorded (a never-booted store says so; refusals cannot be counted), the operator class is DERIVED only where the .recovery row does not attribute the restore (and the mutations blind exactly their own arms), the gc retention carve-out is re-measured every run (a surviving snapshot's dir is retained, a pruned one's is reaped), and the output is byte-deterministic and independent of any self-report."
