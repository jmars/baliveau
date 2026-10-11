#!/bin/sh
# tests/test_fx_select.sh — THE DISCRIMINATION PROOF for THE SELECTION STEP.
#
# tools/fx-select.c computes which generation the system SHOULD be running
# under the lexicographic order over a BOUNDED candidate set — the incumbent
# and the change it replaced — and ENFORCES it: viability (.bootlog) ->
# coherence (fxstore verify, CURRENT only) -> maximise the Osier share, which
# is a TIE-BREAKER and not an objective over all of history (design record
# §7.1).  A seat whose order can be printed and ignored would pass a shape
# test and fail its purpose, so every arm below is written with its FAILING
# DIRECTION named: each one is a scene in which the WRONG implementation
# (rank by share alone; rank outside the bound; always keep the newest;
# revert on a tie; count an unmeasurable candidate as 0%; act on a state the
# seat should withhold; act without --apply) answers DIFFERENTLY.  THREE
# arms additionally prove they CAN fail, by mutating the seat — drop the
# viability filter (S1), drop the coherence filter (S2), drop the tie clause
# (S4) — and each mutant is asserted to go blind on EXACTLY its own fixture,
# with a cmp guard so a sed that matches nothing FAILS the gate instead of
# comparing the code to itself.
#
#   S1  HEADLINE: every top-share generation FAILED its boot -> the decision
#       must NOT name one.  FAILING DIRECTION: a seat that ranks by share
#       alone names the failed 1.000000 generation (the S1 mutant is exactly
#       that seat and is asserted to name it).
#   S2  the highest-share viable CANDIDATE is the incumbent and DRIFTS -> not
#       eligible; the lower-share generation it replaced wins.  FAILING
#       DIRECTION: a seat that measures coherence after the share, or not at
#       all, keeps the drifting incumbent (the S2 mutant does).
#   S3  among the bound's eligible candidates the MAX share wins, not the
#       newest.  FAILING DIRECTION: "always keep the newest" returns keep.
#   S4  a TIE does not cause a revert (keep the incumbent).
#   S4-mutant: the tie clause dropped -> the older twin wins on a tie.
#   S4b versions ABOVE CURRENT are outside the bound (`fxstore rollback
#       --hard` leaves them in the timeline): they are named not-candidate
#       and cannot be reverted forward to.
#   S5a an oracle-refusing INCUMBENT WITHHOLDS — exit 3, and the same value
#       under --apply, with the refusal NAMED.  FAILING DIRECTION: the
#       pre-fix seat printed `decision revert-to <v>` exit 0 for a
#       comparison whose incumbent side was never measured, and a harness
#       reading the frozen record would act where --apply refuses.
#   S5b NO eligible candidate -> a NAMED refusal and exit 1.  FAILING
#       DIRECTION: a keep-by-default seat exits 0 with a decision the
#       records do not support.
#   S6  THE DEFAULT NEVER MUTATES: the store's records AND the --rootfs hash
#       identically before and after a plain (non-apply) run.
#   S7  determinism: two runs are cmp-identical.
#   S8a --apply whose decision is `keep` REFUSES (exit 0, no rollback, the
#       store byte-unchanged, and NO SELECT record).  FAILING DIRECTION: a
#       trigger that fires on every run dresses a no-op as an action.
#   S8b --apply whose winner is the generation CURRENT replaced LANDS, by
#       asymmetry (the pre-apply store did not hold the new version) with the
#       VERSION NUMBER INCREASED, and the SELECT record carries the outcome.
#   S8c/S8d the seat does NOT undo its own rollback: the republished version
#       has not booted, so the run after --apply WITHHOLDS (exit 3) instead
#       of reverting back; once a boot judges it (line pair + materialized
#       generation) the seat keeps it and a second --apply refuses.
#   S9  the order table (all 8 steps) prints on every run (auditable).
#   S10 the 3-field LEGACY .bootlog shape is tolerated with its meaning
#       stated (the order table says what it is) — gated, not just claimed.
#   S11 a missing oracle is a TOOL ERROR (exit 2), never a 0%.
#   S12 the STRICT torn rule: a torn tail naming a candidate poisons it even
#       when a complete verdict exists (outcome.c:1032-1035 is laxer).
#   S12b a torn tail naming CURRENT withholds (exit 3).
#   S13 a mid-boot incumbent (`in-progress` last line) WITHHOLDS: the
#       pre-fix seat reverted a system that is booting right now.
#   S15 an excluded CHALLENGER is named and blocks nothing (keep the measured
#       incumbent) — the mirror of S5a, stated rather than left implicit.
#   S16 a DAMAGED line naming a candidate poisons it (the merged-line hole
#       fx-init's un-repaired append produces, init.zig:764-780).
#   S17 THE BOUND: candidates = {CURRENT, the generation it replaced}; the
#       intermediate snapshot a two-snapshot publish leaves behind (same
#       generation genhash as its own predecessor) is NOT a candidate and
#       cannot tie-break into the winner.
#
# THE FIXTURE is TOOLCHAIN-FREE, exactly like tests/test_osier_share.sh:
# fx-init's activate_paths computes the closure and prints <hash>-<name>,
# the test pre-creates each dir, and the REAL host-side fx-activate writes
# the version-bound facts and publishes a snapshot.  Nothing boots, nothing
# compiles, the recipes never run.  Several configs are activated IN
# SEQUENCE so the store holds multiple published versions with DIFFERENT
# run-set shares:
#   E     runs nothing store-owned                 -> run_set_share 0.000000
#   O     runs the Osier component                 -> 1.000000
#   OC    runs the Osier component AND a C one     -> 0.717523 (MEASURED)
#   OD    O + an Osier package in the closure that NOBODY runs -> 1.000000
#         (the tie arm: same run set, different closure)
# The .bootlog verdict lines are hand-appended in the WRITER's exact shape
# (init.zig:769 `fprintf(f, "%u %s %u %s\n", v, status, epoch, nonce)`),
# as the real line PAIR (in-progress then the verdict, test_fx_audit.sh's
# discipline), with `none` in the nonce field (the writer's placeholder for
# a boot with no host token).
#
# SIBLING RESOLUTION — the repo's ONE policy (tests/test_sibling_paths.sh,
# the sibling-path sweep's gate): $FX_SIBLINGS WINS when set, else the
# historical neighbour $REPO/.. IF it really holds fx-init, else
# $HOME/fixpoint-linux; and $FX_INIT_REPO / $FXSTORE_BIN override the two
# binaries individually.  This gate does NOT copy the stale `$REPO/..`
# default the ten older gates used, under which they SKIPPED (exit 77) about
# a path that could never be right again, quietly enough to read as a pass.
#
# Env: FXSTORE_BIN, FX_INIT_REPO, FX_SIBLINGS, SELECT_BIN, OSIER_BIN,
#      FXSELECT_KEEP=1 (keep the scratch dirs).
set -u

fail() { echo "test_fx_select: FAIL: $*" >&2; exit 1; }
skip() { echo "test_fx_select: SKIP ($*)"; exit 77; }

cd "$(dirname "$0")/.." || fail "cannot cd to repo root"
REPO="$PWD"

command -v cc >/dev/null 2>&1 || skip "cc not found"
command -v sha256sum >/dev/null 2>&1 || skip "sha256sum not found"

# ── sibling resolution: THE REPO'S ONE POLICY (tests/test_sibling_paths.sh,
#    landed by the sibling-path sweep while this unit was in review) ──────
# FX_SIBLINGS is an explicit override and WINS (even a bogus one — then this
# gate SKIPS loudly naming it); else the historical neighbour $REPO/.. is kept
# only if it actually holds the stack; else the relocated default.
SIBS="${FX_SIBLINGS:-$(cd "$REPO/.." && pwd)}"
[ -d "$SIBS/fx-init" ] || [ -n "${FX_SIBLINGS:-}" ] || SIBS="$HOME/fixpoint-linux"
[ -d "$SIBS/fx-init" ] || skip "no fx-init checkout at $SIBS (set FX_SIBLINGS)"
echo "test_fx_select: siblings at $SIBS"

FXSTORE="${FXSTORE_BIN:-$SIBS/fxstore/zig-out/bin/fxstore}"
[ -x "$FXSTORE" ] || skip "fxstore binary missing at $FXSTORE (build the sibling)"
"$FXSTORE" --help 2>&1 | grep -q 'fxstore verify' || skip "fxstore at $FXSTORE is too old (no verify subcommand)"
"$FXSTORE" --help 2>&1 | grep -q 'fxstore rollback' || skip "fxstore at $FXSTORE is too old (no rollback subcommand)"

INIT="${FX_INIT_REPO:-$SIBS/fx-init}"
[ -d "$INIT" ] || skip "fx-init checkout not found at $INIT (set FX_INIT_REPO)"
DL="$SIBS/datalog-dafsa/zig-out/lib"

SELECT="${SELECT_BIN:-$REPO/build/fx-select}"
[ -x "$SELECT" ] || fail "no seat binary at $SELECT (make test-select builds it)"
OSIER="${OSIER_BIN:-$REPO/build/fx-osier-share}"
[ -x "$OSIER" ] || fail "no oracle binary at $OSIER (make test-osier-share builds it)"

# the host-runnable fx-init binaries: the sibling's own build if present,
# else the repo's staging build (test_osier_share.sh's shape).
ZB="$INIT/zig/zig-out/bin"
if [ ! -x "$ZB/activate_paths" ] || [ ! -x "$ZB/fx-activate" ]; then
    ZB="$REPO/build/guest-payload/init-x86_64-musl/bin"
fi
if [ ! -x "$ZB/activate_paths" ] || [ ! -x "$ZB/fx-activate" ]; then
    command -v zig >/dev/null 2>&1 || skip "no host-runnable fx-init binaries at $ZB and zig not found to build them"
    echo "test_fx_select: building fx-init's binaries (x86_64-linux-musl)"
    ZB="$REPO/build/guest-payload/init-x86_64-musl/bin"
    ( cd "$INIT/zig" && zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe \
        -p "$REPO/build/guest-payload/init-x86_64-musl" \
        --cache-dir "$REPO/build/guest-payload/zig-init-cache" ) || fail "fx-init zig build failed"
fi
[ -x "$ZB/fx-activate" ] || fail "no fx-activate at $ZB"
[ -x "$ZB/activate_paths" ] || fail "no activate_paths at $ZB"

# the staging is a CACHE: an fx-activate from before src_of landed would
# drive the OLD writer and every share arm below would fail for the wrong
# reason.  Probe the CAPABILITY, not a ref.
grep -aq src_of "$ZB/fx-activate" || \
    skip "staged fx-activate at $ZB predates src_of — rm -rf build/guest-payload/init-x86_64-musl and re-run"

# the LD_LIBRARY_PATH the host-runnable fx-init binaries need (their baked
# rpath points at the build host's own checkout path)
[ -f "$DL/libdatalog.so" ] || skip "libdatalog.so missing at $DL"
FXLD="$DL"
if [ -n "${LD_LIBRARY_PATH:-}" ]; then FXLD="$DL:$LD_LIBRARY_PATH"; fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fxselect.XXXXXX")" || fail mktemp
if [ "${FXSELECT_KEEP:-0}" = "1" ]; then
    trap 'echo "test_fx_select: scratch kept at $WORK"' EXIT
else
    trap 'rm -rf "$WORK"' EXIT
fi

# ── the oracle's capability probe (a store with no snapshots is enough) ──
mkdir -p "$WORK/capprobe"
if "$FXSTORE" facts src_of --store "$WORK/capprobe" 2>&1 | grep -q "unknown relation 'src_of'"; then
    skip "fxstore at $FXSTORE predates 'facts src_of' — rebuild the sibling checkout"
fi

# ── generic helpers ─────────────────────────────────────────────────────

versions_of() { # versions_of STORE -> "1 2 3 ..." (ascending)
    "$FXSTORE" timeline --store "$1" 2>/dev/null \
        | sed -n 's/^ *\([0-9][0-9]*\).*/\1/p' | tr '\n' ' '
}
current_of() { cat "$1/.db/snapshots/CURRENT" 2>/dev/null | tr -d ' \n'; }
act_first() { cat "$WORK/$1/act.$2.first"; }
act_last()  { cat "$WORK/$1/act.$2.last"; }

run_select() { # run_select OUTFILE [args...] -> echoes the exit code
    _out="$1"; shift
    FXSTORE_BIN="$FXSTORE" "$SELECT" "$@" > "$_out" 2>&1
    echo $?
}
decision_version() { sed -n 's/^decision\t[a-z-]*\t\([0-9][0-9]*\)\t.*/\1/p' "$1" | head -1; }
decision_kind()    { sed -n 's/^decision\t\([a-z-]*\)\t.*/\1/p' "$1" | head -1; }

# expected_winner FILE -> "<version> <share>": the ORDER re-applied to the
# seat's OWN printed candidate table (greatest share, then highest version,
# over the rows it marked eligible).  This audits the DECISION against the
# TABLE the seat printed — not circular: a seat that ranked by share alone,
# or by version alone, would disagree with its own table.
# floats: `test` compares integers, and the objective is a fraction
fgt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>b)}' || fail "$3"; }
flt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a<b)}' || fail "$3"; }
feq() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a==b)}' || fail "$3"; }
share_of()   { awk -F'\t' -v v="$2" '$1=="candidate" && $2==v {print $9; exit}' "$1"; }
state_of()   { awk -F'\t' -v v="$2" '$1=="candidate" && $2==v {print $5; exit}' "$1"; }
share_state_of() { awk -F'\t' -v v="$2" '$1=="candidate" && $2==v {print $11; exit}' "$1"; }
is_cand()    { awk -F'\t' -v v="$2" '$1=="candidate" && $2==v {print ($22=="yes")?"yes":"no"; exit}' "$1"; }
nc_reason()  { awk -F'\t' -v v="$2" '$1=="not-candidate" && $2==v {print $3; exit}' "$1"; }
cand_set()   { awk -F'\t' '$1=="candidate-set" {print $2, $3, $4; exit}' "$1"; }
# the greatest share among the CANDIDATES that are viable (the premise of S2:
# the incumbent holds it and still must lose on drift)
max_cand_viable_share() {
    awk -F'\t' '$1=="candidate" && $22=="yes" && $5=="ok" {s=$9+0; if(!got||s>m){m=s;got=1}}
                 END{if(got)printf "%.6f\n",m}' "$1"
}
# THE ORDER RE-APPLIED to the seat's OWN printed table: greatest share among
# the rows it marked eligible AND in the bound, a TIE going to the incumbent.
# Not circular: a seat that ranked outside the bound, by share alone, or by
# version, would disagree with its own table.
expected_winner() {
    awk -F'\t' '$1=="candidate" && $19=="yes" && $22=="yes" {
                    v=$2+0; sh=$9+0; cur=($3=="1")?1:0;
                    if (!got) { got=1; bs=sh; bv=v; bc=cur }
                    else if (sh>bs) { bs=sh; bv=v; bc=cur }
                    else if (sh==bs && cur) { bv=v; bc=cur }
                 }
                 END { if (got) print bv }' "$1"
}
rootfs_hash() { ( cd "$1" && find . -type f -exec sha256sum {} + 2>/dev/null | LC_ALL=C sort
                 find . -type l 2>/dev/null | LC_ALL=C sort | while IFS= read -r l; do
                     printf 'link %s -> %s\n' "$l" "$(readlink "$l")"; done ) | sha256sum | awk '{print $1}'; }

# store_hash STORE — content hash of every record AND link the store holds.
# Links matter: the install targets ARE symlinks into the store, and a
# mutation that only repointed one would be invisible to a file-only hash.
store_hash() {
    ( cd "$1" || exit 1
      find . -type f -exec sha256sum {} + 2>/dev/null | LC_ALL=C sort
      find . -type l 2>/dev/null | LC_ALL=C sort | while IFS= read -r l; do
          printf 'link %s -> %s\n' "$l" "$(readlink "$l")"
      done ) | sha256sum | awk '{print $1}'
}

# materialize_rootfs STORE ROOTFS VERSION — create every path the install
# facts name (the rootfs links, the store files they point at, the
# generation's own files), then prove `fxstore verify` is CLEAN, so an arm
# that drifts is not blamed on the materialization.
# (test_fx_audit.sh:381-424, reused verbatim in shape.)
materialize_rootfs() {
    _st="$1"; _rt="$2"; _v="$3"
    "$FXSTORE" facts install --as-of "$_v" --store "$_st" \
        | while IFS="$(printf '\t')" read -r tgt org mode gh; do
            [ -n "$tgt" ] || continue
            mkdir -p "$_rt/$(dirname "$tgt")" || exit 1
            rm -f "$_rt$tgt"
            if [ "$mode" = "0" ]; then
                [ -d "$_st/$org" ] || exit 1
                ln -s "$_st/$org" "$_rt$tgt" || exit 1
            else
                mkdir -p "$_st/$(dirname "$org")" || exit 1
                : > "$_st/$org" || exit 1
                : > "$_rt$tgt" || exit 1
            fi
        done || fail "cannot materialize rootfs from install facts"
    "$FXSTORE" facts svc_bin --as-of "$_v" --store "$_st" \
        | while IFS="$(printf '\t')" read -r name bin; do
            case "$bin" in /*) continue ;; esac
            [ -n "$bin" ] || continue
            mkdir -p "$_st/$(dirname "$bin")" || exit 1
            : > "$_st/$bin" || exit 1
        done || fail "cannot materialize svc_bin paths"
    "$FXSTORE" facts generation --as-of "$_v" --store "$_st" \
        | while IFS="$(printf '\t')" read -r gh bf dh ep; do
            mkdir -p "$_st/$(dirname "$bf")" "$_st/$(dirname "$dh")" || exit 1
            : > "$_st/$bf" || exit 1
            : > "$_st/$dh" || exit 1
        done || fail "cannot materialize the generation's files"
    "$FXSTORE" verify "$_rt" --as-of "$_v" --store "$_st" >/dev/null 2>&1 \
        || fail "precondition: fxstore verify is not clean on the fixture (rootfs materialization is wrong)"
}

# write_bootlog STORE [V:STATE ...] — one REAL line pair per judged version
# (in-progress, then the verdict), default state `ok`; STATE may be
# ok|failed|in-progress|none (no line at all) |torn (an unterminated final
# line naming V, which ends the file).  LEGACY=1 writes the 3-field
# pre-nonce shape instead.
write_bootlog() {
    _st="$1"; shift
    : > "$_st/.bootlog"
    _e=1700000000
    for _v in $(versions_of "$_st"); do
        _s=ok
        for _sp in "$@"; do
            case "$_sp" in "$_v":*) _s="${_sp#*:}" ;; esac
        done
        case "$_s" in none) continue ;; esac
        _e=$((_e + 1))
        if [ "$_s" = "torn" ]; then
            printf '%u failed %u' "$_v" "$_e" >> "$_st/.bootlog"   # NO newline: torn, and last
            return 0
        fi
        if [ "${LEGACY:-0}" = "1" ]; then
            printf '%u in-progress %u\n' "$_v" "$_e" >> "$_st/.bootlog"
            printf '%u %s %u\n' "$_v" "$_s" "$_e" >> "$_st/.bootlog"
        else
            printf '%u in-progress %u none\n' "$_v" "$_e" >> "$_st/.bootlog"
            printf '%u %s %u none\n' "$_v" "$_s" "$_e" >> "$_st/.bootlog"
        fi
    done
    return 0
}

# ── the fixture: NAME, then the configs to activate IN ORDER ────────────
build_fixture() {
    _name="$1"; _order="$2"
    FD="$WORK/$_name"
    ST="$FD/store"
    mkdir -p "$ST" "$FD/src/osier-svc" "$FD/src/c-svc" "$FD/src/deadwood" "$FD/src/tool" \
        || fail "cannot create the fixture tree"
    SRC="$FD/src"
    {
        echo "-- the osier main module of the selection fixture"
        i=0; while [ $i -lt 9 ]; do echo "main_line_$i = \\(i + $i) -- osier source"; i=$((i+1)); done
    } > "$SRC/osier-svc/Main.elm"
    {
        echo "-- the osier util module"
        i=0; while [ $i -lt 3 ]; do echo "util_line_$i = $i -- osier source"; i=$((i+1)); done
    } > "$SRC/osier-svc/Util.elm"
    {
        echo "/* a C service the generation also runs */"
        i=0; while [ $i -lt 7 ]; do echo "static int c_line_$i = $i; /* not osier */"; i=$((i+1)); done
    } > "$SRC/c-svc/main.c"
    {
        echo "-- dead osier code: built into the closure, run by nobody"
        i=0; while [ $i -lt 11 ]; do echo "dead_line_$i = $i -- osier source"; i=$((i+1)); done
    } > "$SRC/deadwood/Dead.elm"
    {
        echo "/* the tool packages share this tree */"
        i=0; while [ $i -lt 5 ]; do echo "int tool_line_$i = $i;"; i=$((i+1)); done
    } > "$SRC/tool/tool.c"

    PSN=0
    ps_pkg() {
        if [ "$PSN" -eq 0 ]; then echo "  { name = \"$1\", version = \"0\""
        else echo "  , { name = \"$1\", version = \"0\""; fi
        PSN=$((PSN+1))
        cat <<EOF
    , src = < Path = "$2" >
    , deps = [] : List Text
    , excludes = [] : List Text
    , build = { target = "$1", recipe = [] : List Action } }
EOF
    }
    {
        cat <<'EOF'
let Action = < Shell : Text | Copy : { from : Text, to : Text } | Mkdir : Text
             | Rm : Text | Touch : Text | Move : { from : Text, to : Text }
             | Symlink : { from : Text, to : Text } | Chmod : { path : Text, mode : Text }
             | Echo : Text | Env : { key : Text, value : Text } | Run : { argv : List Text } >
let Src = < Path : Text | Fetch : { url : Text, hash : Text } >
EOF
        echo "let Package = { name : Text, version : Text, src : Src, deps : List Text,"
        echo "                excludes : List Text, build : { target : Text, recipe : List Action } }"
        echo "in  { packages = ["
        ps_pkg dhake       "$SRC/tool"
        ps_pkg fx-init     "$SRC/tool"
        ps_pkg fxctl       "$SRC/tool"
        ps_pkg fx-activate "$SRC/tool"
        ps_pkg osier-svc   "$SRC/osier-svc"
        ps_pkg c-svc       "$SRC/c-svc"
        ps_pkg deadwood    "$SRC/deadwood"
        echo "  ] }"
    } > "$FD/package-set.dhall" || fail "cannot write the package set"
    PS="$FD/package-set.dhall"

    PATHS=$(LD_LIBRARY_PATH="$FXLD" "$ZB/activate_paths" --store "$ST" --package-set "$PS" \
        dhake fx-init fxctl fx-activate osier-svc c-svc deadwood) || fail "activate_paths failed"
    [ -n "$PATHS" ] || fail "activate_paths printed no closure"
    echo "$PATHS" | while IFS= read -r pd; do
        mkdir -p "$ST/$pd" || exit 1
    done || fail "cannot create the closure dirs"

    cfg_write() { # cfg_write OUT PKGLIST SVCS
        cat > "$1" <<EOF
let Probe = < Tcp : Natural | Unix : Text | File : Text >
let Service = { name : Text, argv : List Text, pkg : Optional Text, on : Text,
                restart : Optional Text, backoffMs : Optional Natural,
                probe : Optional Probe,
                env : Optional (List { key : Text, value : Text }),
                console : Optional Text }
let User = { name : Text, uid : Natural, groups : List Text }
in  { hostname = "$_name"
    , packages = [ $2 ]
    , users = [ { name = "root", uid = 0, groups = [] : List Text } ] : List User
    , services = [ $3 ] : List Service
    , extraEtc = None (List { path : Text, content : Text })
    , bootGraceMs = Some 30000
    , agentService = None Text
    }
EOF
    }
    TOOLS='"dhake", "fx-init", "fxctl", "fx-activate"'
    SVC_SH='{ name = "shsvc", argv = [ "/bin/sh", "-c", "true" ], pkg = None Text, on = "all", restart = Some "always", backoffMs = Some 500, probe = None Probe, env = None (List { key : Text, value : Text }), console = None Text }'
    SVC_O='{ name = "osierd", argv = [ "osier-svc" ], pkg = Some "osier-svc", on = "all", restart = Some "always", backoffMs = Some 500, probe = None Probe, env = None (List { key : Text, value : Text }), console = None Text }'
    SVC_C='{ name = "cd", argv = [ "c-svc" ], pkg = Some "c-svc", on = "all", restart = Some "always", backoffMs = Some 500, probe = None Probe, env = None (List { key : Text, value : Text }), console = None Text }'
    cfg_write "$FD/E.dhall"  "$TOOLS"                       "$SVC_SH"
    cfg_write "$FD/O.dhall"  "$TOOLS, \"osier-svc\""        "$SVC_SH, $SVC_O"
    cfg_write "$FD/OC.dhall" "$TOOLS, \"osier-svc\", \"c-svc\"" "$SVC_SH, $SVC_O, $SVC_C"
    cfg_write "$FD/OD.dhall" "$TOOLS, \"osier-svc\", \"deadwood\"" "$SVC_SH, $SVC_O"

    _n=0
    for _cfg in $_order; do
        _n=$((_n + 1))
        _before=$(versions_of "$ST")
        _out=$(LD_LIBRARY_PATH="$FXLD" "$ZB/fx-activate" --store "$ST" --package-set "$PS" \
            --config "$FD/$_cfg.dhall" 2>&1) || fail "fx-activate $_cfg failed: $_out"
        _after=$(versions_of "$ST")
        # activate_paths already published snapshots: record only the
        # versions THIS activation ADDED (a set difference, so an activation
        # that publishes more than one snapshot is tracked exactly)
        _new=""
        for _v in $_after; do
            case " $_before " in *" $_v "*) ;; *) _new="$_new $_v" ;; esac
        done
        _first=$(echo $_new | awk '{print $1}')
        _last=$(echo $_new | awk '{print $NF}')
        [ -n "$_first" ] && [ -n "$_last" ] || fail "could not identify the versions $_cfg published"
        echo "$_first" > "$FD/act.$_n.first"
        echo "$_last"  > "$FD/act.$_n.last"
    done
    RT="$FD/rootfs"
    mkdir -p "$RT"
    echo "test_fx_select: $_name built: versions $(versions_of "$ST") CURRENT $(current_of "$ST"); activations $_order"
}

# ═══ fix1 — order E O OC ═══════════════════════════════════════════════
echo "== fixtures"
build_fixture fix1 "E O OC"
F1="$WORK/fix1"; S1="$F1/store"; P1="$F1/package-set.dhall"
F1_E_LAST=$(act_last fix1 1)
F1_O_FIRST=$(act_first fix1 2); F1_O_LAST=$(act_last fix1 2)
F1_C_FIRST=$(act_first fix1 3); F1_C_LAST=$(act_last fix1 3)
echo "test_fx_select: fix1 E/$F1_E_LAST  O/$F1_O_FIRST-$F1_O_LAST  OC/$F1_C_FIRST-$F1_C_LAST (CURRENT)"
[ "$(current_of "$S1")" = "$F1_C_LAST" ] || fail "fix1: CURRENT is not the last OC version"
materialize_rootfs "$S1" "$F1/rootfs" "$(current_of "$S1")"
SEL="--store $S1 --rootfs $F1/rootfs --fxstore $FXSTORE --oracle $OSIER --package-set $P1"

# ── S9: the order table prints on every run (the rule is auditable) ─────
write_bootlog "$S1"
h_before=$(store_hash "$S1"); rt_before=$(rootfs_hash "$F1/rootfs")
rc=$(run_select "$F1/o.s9" $SEL)
[ "$rc" = "0" ] || fail "S9: expected exit 0, got $rc: $(sed -n 1,6p "$F1/o.s9")"
for _n in 1 2 3 4 5 6 7 8; do
    grep -q "^order	$_n	" "$F1/o.s9" || fail "S9: order step $_n missing"
done
grep -q '^order	1	candidates	' "$F1/o.s9" || fail "S9: the frozen order table is not in the output"
grep -q '^order	8	apply	' "$F1/o.s9" || fail "S9: the apply step of the order is not printed"
grep -q '^bound	candidate-set-is-a-pair	' "$F1/o.s9" || fail "S9: no bound states what the candidate bound cannot see"
grep -q '^bound	share-of-a-partial-snapshot	' "$F1/o.s9" || fail "S9: the bounds table is not printed"
echo "test_fx_select: S9 the order table (8 steps) + bounds print on every run"

# ── S17: THE BOUND (rule 1) — the intermediate is NOT a candidate ───────
# Failing direction: a seat whose candidates are EVERY published version (the
# pre-fix rule) ties the intermediate with the generation it duplicates and
# then prefers it (highest version) — so the winner here would be the
# intermediate $F1_C_FIRST, not the change CURRENT actually replaced.
read -r cs_cur cs_pred cs_n <<EOF
$(cand_set "$F1/o.s9")
EOF
[ "$cs_cur" = "$F1_C_LAST" ] || fail "S17: the candidate set does not name CURRENT ($cs_cur)"
[ "$cs_pred" = "$F1_O_LAST" ] || fail "S17: the predecessor is not the O generation's last version $F1_O_LAST but '$cs_pred'"
[ "$cs_n" = "2" ] || fail "S17: expected exactly 2 candidates, got $cs_n"
[ "$(is_cand "$F1/o.s9" "$F1_C_LAST")" = "yes" ] || fail "S17: CURRENT is not a candidate"
[ "$(is_cand "$F1/o.s9" "$F1_O_LAST")" = "yes" ] || fail "S17: the change CURRENT replaced is not a candidate"
[ "$(is_cand "$F1/o.s9" "$F1_C_FIRST")" = "no" ] || fail "S17: the INTERMEDIATE v$F1_C_FIRST is a candidate"
case "$(nc_reason "$F1/o.s9" "$F1_C_FIRST")" in
    republication-of-its-immediate-predecessor*) ;;
    *) fail "S17: the intermediate's non-candidacy is not named as a republication: $(nc_reason "$F1/o.s9" "$F1_C_FIRST")";;
esac
grep -q "^not-candidate	$F1_O_FIRST	" "$F1/o.s9" || fail "S17: v$F1_O_FIRST has no not-candidate record"
case "$(nc_reason "$F1/o.s9" "$F1_O_FIRST")" in
    older-than-the-predecessor*) ;;
    *) fail "S17: v$F1_O_FIRST's non-candidacy is not named as older-than-the-predecessor: $(nc_reason "$F1/o.s9" "$F1_O_FIRST")";;
esac
[ -n "$(nc_reason "$F1/o.s9" 1)" ] || fail "S17: v1 has no named reason for being outside the bound"
[ "$(state_of "$F1/o.s9" "$F1_C_FIRST")" = "ok" ] \
    || fail "S17: the intermediate is not viable in its own row (the tie must be killed by the BOUND, not by viability): $(state_of "$F1/o.s9" "$F1_C_FIRST")"
echo "test_fx_select: S17 the bound holds: candidates = CURRENT v$cs_cur + predecessor v$cs_pred; the intermediate v$F1_C_FIRST (share-equal twin) is not-candidate"

# ── S3: the MAX share wins among the BOUND's eligible candidates, not the
#        newest.  FAILING DIRECTION: "always keep the newest" returns keep;
#        this arm must return revert-to the OLDER predecessor. ───────────
ckind=$(decision_kind "$F1/o.s9"); cver=$(decision_version "$F1/o.s9")
[ "$ckind" = "revert-to" ] || fail "S3: expected revert-to, got '$ckind': $(grep -m1 '^decision' "$F1/o.s9")"
[ "$cver" != "$F1_C_LAST" ] || fail "S3: the newest generation held the LOWER share, so a keep is the wrong answer"
[ "$cver" = "$cs_pred" ] || fail "S3: the winner is not the generation CURRENT replaced ($cs_pred), got $cver"
[ "$cver" = "$(expected_winner "$F1/o.s9")" ] \
    || fail "S3: the decision (v$cver) is not the choice the printed table entails (v$(expected_winner "$F1/o.s9"))"
[ "$(is_cand "$F1/o.s9" "$cver")" = "yes" ] || fail "S3: the winner is not a candidate"
w_share=$(share_of "$F1/o.s9" "$cver"); cur_share=$(share_of "$F1/o.s9" "$F1_C_LAST")
fgt "$w_share" "$cur_share" "S3: the winner's share $w_share does not exceed CURRENT's $cur_share"
echo "test_fx_select: S3 max share wins over newest (revert-to v$cver at $w_share, CURRENT v$F1_C_LAST holds $cur_share)"

# ── S6: THE DEFAULT NEVER MUTATES (store AND rootfs) ───────────────────
# FAILING DIRECTION: a seat that rewrote a record (or touched the rootfs it
# was handed) to answer the question.
rc=$(run_select "$F1/o.s6" $SEL)
[ "$rc" = "0" ] || fail "S6: expected exit 0, got $rc"
[ "$h_before" = "$(store_hash "$S1")" ] || fail "S6: a plain run MUTATED the store"
[ "$rt_before" = "$(rootfs_hash "$F1/rootfs")" ] || fail "S6: a plain run MUTATED the --rootfs it was handed"
cmp -s "$F1/o.s6" "$F1/o.s9" || fail "S6: the second plain run's output differs from the first"
# ── S7: determinism, stated as its own arm ──────────────────────────────
rc=$(run_select "$F1/o.s7" $SEL)
[ "$rc" = "0" ] || fail "S7: expected exit 0, got $rc"
cmp -s "$F1/o.s6" "$F1/o.s7" || fail "S7: two runs over the same store are not byte-identical"
echo "test_fx_select: S6 no mutation without --apply (store + rootfs); S7 two runs cmp-identical"

# ── S1 THE HEADLINE: every top-share generation FAILED its boot ─────────
# FAILING DIRECTION: a seat that ranks by share alone names the failed
# 1.000000 generation (proved by the mutant below).
write_bootlog "$S1" "$F1_O_FIRST:failed" "$F1_O_LAST:failed" "$F1_C_FIRST:failed"
rc=$(run_select "$F1/o.s1" $SEL)
[ "$rc" = "0" ] || fail "S1: expected exit 0, got $rc: $(sed -n 1,6p "$F1/o.s1")"
ckind=$(decision_kind "$F1/o.s1"); cver=$(decision_version "$F1/o.s1")
[ "$ckind" = "keep" ] || fail "S1: the highest-share generation FAILED its boot, so the decision must not be a revert: $(grep -m1 '^decision' "$F1/o.s1")"
[ "$cver" = "$F1_C_LAST" ] || fail "S1: expected keep $F1_C_LAST, got $cver"
for _v in "$F1_O_FIRST" "$F1_O_LAST" "$F1_C_FIRST"; do
    grep -q "^candidate	$_v	0	viability	failed	.*eligible	no" "$F1/o.s1" \
        || fail "S1: v$_v (a top-share generation that FAILED its boot) is not marked failed/not-eligible: $(grep "^candidate	$_v	" "$F1/o.s1")"
    [ "$cver" != "$_v" ] || fail "S1: the decision named v$_v, whose boot FAILED"
done
[ "$cver" = "$(expected_winner "$F1/o.s1")" ] || fail "S1: the decision disagrees with the seat's own table"
[ "$(expected_winner "$F1/o.s1")" != "$F1_O_LAST" ] || fail "S1: the table itself names the failed generation"
echo "test_fx_select: S1 the failed highest-share generation ($F1_O_LAST) is not named -> keep $cver"

# ── S1's PROOF THAT THE ARM CAN FAIL: the sed-mutant ────────────────────
# Drop the viability filter (rank by share alone) and rebuild.  The mutant
# must go blind on EXACTLY the S1 fixture: it names the failed generation.
sed 's/int eligible = c->is_cand && viable && coherent && s->measured;/int eligible = c->is_cand \&\& coherent \&\& s->measured;/' \
    "$REPO/tools/fx-select.c" > "$WORK/fx-select-mutant.c" || fail "S1: cannot write the mutant source"
cmp -s "$WORK/fx-select-mutant.c" "$REPO/tools/fx-select.c" \
    && fail "S1: the mutant source is IDENTICAL to the seat — the sed matched nothing, so the arm would compare the code to itself"
cc -std=c11 -O2 -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE -o "$WORK/fx-select-mutant" \
    "$WORK/fx-select-mutant.c" || fail "S1: the mutant does not compile"
mrc=$(FXSTORE_BIN="$FXSTORE" "$WORK/fx-select-mutant" \
        --store "$S1" --rootfs "$F1/rootfs" --fxstore "$FXSTORE" --oracle "$OSIER" --package-set "$P1" \
        > "$F1/o.s1mut" 2>&1; echo $?)
[ "$mrc" = "0" ] || fail "S1-mutant: expected exit 0, got $mrc"
mkind=$(decision_kind "$F1/o.s1mut"); mver=$(decision_version "$F1/o.s1mut")
[ "$mkind" = "revert-to" ] || fail "S1-mutant: the share-only seat did NOT go blind ($mkind $mver) — the viability filter is not load-bearing on this fixture"
_blind=0
for _v in "$F1_O_FIRST" "$F1_O_LAST" "$F1_C_FIRST"; do
    if [ "$mver" = "$_v" ]; then _blind=1; fi
done
[ "$_blind" = "1" ] || fail "S1-mutant: the share-only seat named v$mver, which is NOT one of the failed generations — the mutant did not go blind on this fixture"
grep -q "^candidate	$mver	0	viability	failed	" "$F1/o.s1mut" \
    || fail "S1-mutant: the mutant's own table does not show the failed verdict it ranked past"
[ "$mver" != "$(decision_version "$F1/o.s1")" ] || fail "S1-mutant: the mutant reached the SAME decision as the seat"
echo "test_fx_select: S1 MUTANT (viability filter dropped) goes blind: revert-to v$mver, a generation marked viability-failed in its own table; the real seat keeps v$F1_C_LAST"

# ── S10: the 3-field LEGACY line shape is tolerated, meaning stated ─────
LEGACY=1 write_bootlog "$S1" "$F1_O_FIRST:failed" "$F1_O_LAST:failed" "$F1_C_FIRST:failed"
rc=$(run_select "$F1/o.s10" $SEL)
[ "$rc" = "0" ] || fail "S10: expected exit 0, got $rc"
grep -q "^candidate	$F1_O_LAST	0	viability	failed	.*the pre-nonce legacy shape" "$F1/o.s10" \
    || fail "S10: the 3-field legacy verdict is not read as a verdict: $(grep "^candidate	$F1_O_LAST	" "$F1/o.s10")"
[ "$(decision_kind "$F1/o.s10")" = "keep" ] || fail "S10: the legacy shape changed the decision"
echo "test_fx_select: S10 the 3-field pre-nonce verdict shape is read (and named as such)"

# ── S16: a DAMAGED line naming a candidate POISONS it (rule 2) ──────────
# A 5-field line is not the writer's shape (init.zig:769 emits 3 or 4).
# FAILING DIRECTION: without the poison, v$F1_O_LAST keeps its earlier `ok`,
# stays viable, and its 1.000000 share wins -> revert-to it on the strength of
# a record the writer never wrote.
write_bootlog "$S1"
printf '%u ok %u none extra-field\n' "$F1_O_LAST" 1799999001 >> "$S1/.bootlog"
rc=$(run_select "$F1/o.s16" $SEL)
[ "$rc" = "0" ] || fail "S16: expected exit 0, got $rc"
[ "$(state_of "$F1/o.s16" "$F1_O_LAST")" = "damaged-line" ] \
    || fail "S16: a damaged line naming v$F1_O_LAST did not poison it: state=$(state_of "$F1/o.s16" "$F1_O_LAST")"
grep -q '^caveat	bootlog-damage	damaged=1	torn=0	' "$F1/o.s16" \
    || fail "S16: the damaged line is not counted: $(grep '^caveat.*bootlog-damage' "$F1/o.s16")"
[ "$(decision_kind "$F1/o.s16")" = "keep" ] \
    || fail "S16: the decision named a generation whose verdict could not be read: $(grep -m1 '^decision' "$F1/o.s16")"
fgt "$(share_of "$F1/o.s9" "$F1_O_LAST")" "$(share_of "$F1/o.s9" "$F1_C_LAST")" \
    "S16: fixture premise broken — the poisoned generation does not hold the greater share, so the arm proves nothing"
echo "test_fx_select: S16 a damaged line naming v$F1_O_LAST poisons it (state=damaged-line, caveat damaged=1) -> keep $F1_C_LAST"

# ── S12: the STRICT TORN rule (rule 2), a case NO earlier arm reached ───
# A torn fragment naming $F1_O_LAST appended AFTER a complete `ok` verdict
# for it: the strict rule poisons it, outcome.c's laxer rule would not (it
# poisons only a version with NO complete verdict).
# FAILING DIRECTION: without the poison v$F1_O_LAST's last clean verdict is
# `ok` and its 1.000000 share wins -> revert-to it while its file was
# mid-write about it.
write_bootlog "$S1"
printf '%u in-progress %u' "$F1_O_LAST" 1799999002 >> "$S1/.bootlog"
rc=$(run_select "$F1/o.s12" $SEL)
[ "$rc" = "0" ] || fail "S12: expected exit 0, got $rc"
[ "$(state_of "$F1/o.s12" "$F1_O_LAST")" = "torn-verdict-unknown" ] \
    || fail "S12: a torn tail naming v$F1_O_LAST did not poison it: state=$(state_of "$F1/o.s12" "$F1_O_LAST")"
grep -q '^caveat	bootlog-damage	damaged=0	torn=1	' "$F1/o.s12" \
    || fail "S12: the torn tail is not counted: $(grep '^caveat.*bootlog-damage' "$F1/o.s12")"
[ "$(decision_kind "$F1/o.s12")" = "keep" ] \
    || fail "S12: the decision named a version whose bootlog was mid-write about it: $(grep -m1 '^decision' "$F1/o.s12")"
echo "test_fx_select: S12 the STRICT torn rule holds: a torn tail naming v$F1_O_LAST ($(state_of "$F1/o.s12" "$F1_O_LAST")) poisons it -> keep $F1_C_LAST"

# ── S13: CURRENT MID-BOOT WITHHOLDS (fix B) ────────────────────────────
# The writer's own line PAIR is in-progress-then-verdict (init.zig:4387), so
# during a boot of the incumbent its LAST line is in-progress.  Treating that
# as merely "not viable" would recommend — and --apply perform — a rollback of
# a system that is booting right now.
# FAILING DIRECTION: the pre-fix seat prints `decision revert-to <predecessor>`
# with exit 0 here, and --apply rolls a live boot back.
write_bootlog "$S1"
printf '%u in-progress %u none\n' "$F1_C_LAST" 1799999003 >> "$S1/.bootlog"
h_before=$(store_hash "$S1")
rc=$(run_select "$F1/o.s13" $SEL)
[ "$rc" = "3" ] || fail "S13: a mid-boot incumbent must WITHHOLD (exit 3), got $rc: $(grep -m1 '^decision' "$F1/o.s13")"
grep -q "^decision	withhold	-	current-verdict-unknown:in-progress	" "$F1/o.s13" \
    || fail "S13: the withholding state is not the named one: $(grep -m1 '^decision' "$F1/o.s13")"
grep -q '^verdict	withhold' "$F1/o.s13" || fail "S13: no withhold verdict"
grep -q '^decision	revert-to' "$F1/o.s13" && fail "S13: a withheld state was printed as revert-to"
rc=$(run_select "$F1/o.s13a" $SEL --apply)
[ "$rc" = "3" ] || fail "S13: --apply on a withheld decision must exit 3, got $rc"
grep -q '^apply	refused	withheld-current-verdict-unknown:in-progress	' "$F1/o.s13a" \
    || fail "S13: --apply did not refuse the withheld state: $(grep '^apply' "$F1/o.s13a")"
[ "$h_before" = "$(store_hash "$S1")" ] || fail "S13: --apply MUTATED the store on a withheld decision"
echo "test_fx_select: S13 a mid-boot incumbent WITHHOLDS (exit 3, plain and --apply agree, store unchanged)"

# ── S12b: a torn tail naming CURRENT withholds too (outcome.c's case) ───
write_bootlog "$S1" "$F1_C_LAST:torn"
rc=$(run_select "$F1/o.s12b" $SEL)
[ "$rc" = "3" ] || fail "S12b: a torn CURRENT must withhold (exit 3), got $rc: $(grep -m1 '^decision' "$F1/o.s12b")"
grep -q "^decision	withhold	-	current-verdict-unknown:torn-verdict-unknown	" "$F1/o.s12b" \
    || fail "S12b: the withholding state is not the named one: $(grep -m1 '^decision' "$F1/o.s12b")"
echo "test_fx_select: S12b a torn tail naming CURRENT withholds (exit 3)"

# ── S8a: --apply where CURRENT IS the winner -> refuses, no mutation ───
write_bootlog "$S1" "$F1_O_FIRST:failed" "$F1_O_LAST:failed" "$F1_C_FIRST:failed"
h_before=$(store_hash "$S1"); v_before=$(versions_of "$S1")
rc=$(run_select "$F1/o.s8a" $SEL --apply)
[ "$rc" = "0" ] || fail "S8a: a keep under --apply must exit 0, got $rc: $(grep -m1 '^apply' "$F1/o.s8a")"
grep -q "^apply	refused	current-already-the-winner" "$F1/o.s8a" \
    || fail "S8a: no named refusal for a no-op: $(grep '^apply' "$F1/o.s8a")"
grep -q "^decision	keep	$F1_C_LAST	" "$F1/o.s8a" || fail "S8a: the decision is not keep $F1_C_LAST"
grep -q '^SELECT	' "$F1/o.s8a" && fail "S8a: a SELECT record was printed for a no-op"
[ "$h_before" = "$(store_hash "$S1")" ] || fail "S8a: --apply on a keep MUTATED the store"
[ "$(versions_of "$S1")" = "$v_before" ] || fail "S8a: --apply on a keep published a version"
echo "test_fx_select: S8a --apply on a keep refuses (exit 0), store byte-unchanged, no version, no SELECT record"

# ── S8b: --apply where the winner is the generation CURRENT replaced ───
write_bootlog "$S1"
pre_current=$(current_of "$S1"); pre_versions=$(versions_of "$S1")
rc=$(run_select "$F1/o.s8b" $SEL --apply)
[ "$rc" = "0" ] || fail "S8b: expected exit 0, got $rc: $(grep '^apply' "$F1/o.s8b")"
w8=$(decision_version "$F1/o.s8b")
[ "$w8" = "$F1_O_LAST" ] || fail "S8b: expected the winner to be the generation CURRENT replaced ($F1_O_LAST), got $w8"
grep -q "^apply	done	soft-rollback	from	$pre_current	to	$w8	" "$F1/o.s8b" \
    || fail "S8b: no soft-rollback record naming the move: $(grep '^apply' "$F1/o.s8b")"
grep -q "^SELECT	$S1	$pre_current	$w8	" "$F1/o.s8b" \
    || fail "S8b: no SELECT record carrying the landed outcome: $(grep '^SELECT' "$F1/o.s8b")"
grep -q '^# SELECT: ' "$F1/o.s8b" || fail "S8b: no loud SELECT line naming what caused the rollback"
post_current=$(current_of "$S1"); post_versions=$(versions_of "$S1")
case " $pre_versions " in *" $post_current "*) fail "S8b: the post-apply CURRENT $post_current already existed before --apply — nothing landed";; esac
[ "$post_current" -gt "$pre_current" ] \
    || fail "S8b: the SOFT rollback did not raise the version number ($pre_current -> $post_current)"
grep -q "^apply	done	soft-rollback	from	$pre_current	to	$w8	new-current	$post_current	version-increased	yes" "$F1/o.s8b" \
    || fail "S8b: the seat did not report the version increase it relies on"
echo "test_fx_select: S8b --apply lands: CURRENT $pre_current -> $post_current (soft, version INCREASED; pre-apply store held neither)"

# ── S8c: the seat does NOT undo its own rollback ───────────────────────
# The soft rollback republished the chosen content under a NEW version
# ($post_current) that has not booted, so the incumbent's only record is
# silence.  MEASURED consequence of the pre-fix rule (never-judged -> not
# viable): the very next run reverted to v$pre_current, i.e. the seat undid
# its own act — a flip-flop a harness looping over the frozen record would
# perform.
# FAILING DIRECTION: the pre-fix seat prints `decision revert-to v$pre_current`
# with exit 0 here (and --apply would land it).
rc=$(run_select "$F1/o.s8c" $SEL)
[ "$rc" = "3" ] || fail "S8c: an un-judged incumbent (freshly rolled back) must WITHHOLD (exit 3), got $rc: $(grep -m1 '^decision' "$F1/o.s8c")"
grep -q "^decision	withhold	-	current-not-judged	" "$F1/o.s8c" \
    || fail "S8c: the withholding state is not the named one: $(grep -m1 '^decision' "$F1/o.s8c")"
grep -q '^decision	revert-to' "$F1/o.s8c" && fail "S8c: the seat undid its own rollback"
# ── S8d: the next boot judges the rolled-back generation -> stable keep ─
# A real next boot writes the line PAIR for the new version and materializes
# its generation; the seat must then keep it and refuse to act.
mkdir -p "$WORK/rowmark"
printf '%u in-progress %u none\n%u ok %u none\n' "$post_current" 1799999010 "$post_current" 1799999010 >> "$S1/.bootlog"
materialize_rootfs "$S1" "$F1/rootfs-post" "$post_current"
h_before=$(store_hash "$S1")
rc=$(run_select "$F1/o.s8d" --store "$S1" --rootfs "$F1/rootfs-post" --fxstore "$FXSTORE" --oracle "$OSIER" --package-set "$P1" --apply)
[ "$rc" = "0" ] || fail "S8d: expected exit 0, got $rc: $(grep -m1 '^decision' "$F1/o.s8d")"
grep -q "^decision	keep	$post_current	" "$F1/o.s8d" || fail "S8d: the judged, materialized current is not kept: $(grep -m1 '^decision' "$F1/o.s8d")"
grep -q "^candidate	$post_current	1	viability	ok	" "$F1/o.s8d" || fail "S8d: the incumbent's own verdict was not read"
grep -q '^apply	refused	current-already-the-winner' "$F1/o.s8d" || fail "S8d: the second --apply did not refuse"
[ "$h_before" = "$(store_hash "$S1")" ] || fail "S8d: the second --apply mutated the store"
echo "test_fx_select: S8c/S8d the rollback is NOT undone (v$post_current un-judged -> withhold exit 3); once a boot judges it -> keep, second --apply refuses, store unchanged"

# ═══ fix2 — order E OC O: CURRENT has the top share and DRIFTS ═════════
build_fixture fix2 "E OC O"
F2="$WORK/fix2"; S2="$F2/store"; P2="$F2/package-set.dhall"
F2_C_LAST=$(act_last fix2 2); F2_O_LAST=$(act_last fix2 3)
[ "$(current_of "$S2")" = "$F2_O_LAST" ] || fail "fix2: CURRENT is not the last O version"
materialize_rootfs "$S2" "$F2/rootfs" "$(current_of "$S2")"
echo "payload" > "$F2/rootfs/bin/rogue"        # an unmanaged rootfs file (test_fx_audit.sh's drift shape)
"$FXSTORE" verify "$F2/rootfs" --as-of "$(current_of "$S2")" --store "$S2" >/dev/null 2>&1 \
    && fail "S2: precondition: the fixture rootfs is not drifting"
write_bootlog "$S2"
SEL2="--store $S2 --rootfs $F2/rootfs --fxstore $FXSTORE --oracle $OSIER --package-set $P2"
rc=$(run_select "$F2/o.s2" $SEL2)
[ "$rc" = "0" ] || fail "S2: expected exit 0, got $rc"
# FAILING DIRECTION: a seat that measures coherence after (or not at all)
# keeps the drifting CURRENT, which holds the greatest share here.
grep -q "^candidate	$F2_O_LAST	1	viability	ok	.*coherence	drift	.*eligible	no" "$F2/o.s2" \
    || fail "S2: the drifting CURRENT is not marked drift/not-eligible: $(grep "^candidate	$F2_O_LAST	1" "$F2/o.s2")"
cur_share=$(share_of "$F2/o.s2" "$F2_O_LAST")
mvs=$(max_cand_viable_share "$F2/o.s2")
feq "$cur_share" "$mvs" "S2: fixture premise broken — the incumbent holds $cur_share but the greatest viable CANDIDATE share is $mvs (the arm's whole point is a max-share incumbent)"
[ "$(decision_kind "$F2/o.s2")" = "revert-to" ] || fail "S2: expected revert-to the generation it replaced: $(grep -m1 '^decision' "$F2/o.s2")"
w=$(decision_version "$F2/o.s2")
[ "$w" = "$F2_C_LAST" ] || fail "S2: expected the predecessor v$F2_C_LAST, got v$w"
[ "$w" = "$(expected_winner "$F2/o.s2")" ] || fail "S2: the decision v$w disagrees with the table v$(expected_winner "$F2/o.s2")"
[ "$(is_cand "$F2/o.s2" "$w")" = "yes" ] || fail "S2: the winner is not a candidate"
flt "$(share_of "$F2/o.s2" "$w")" "$cur_share" "S2: the winner v$w does not hold a LOWER share than the drifting incumbent ($cur_share)"
grep -q "^drift	$F2_O_LAST	" "$F2/o.s2" || fail "S2: the drift is not reported as its own record"
echo "test_fx_select: S2 a drifting incumbent ($F2_O_LAST) is not eligible; the lower-share v$w wins"

# ── S2's PROOF THAT THE ARM CAN FAIL: drop the COHERENCE filter ────────
sed 's/int eligible = c->is_cand && viable && coherent && s->measured;/int eligible = c->is_cand \&\& viable \&\& s->measured;/' \
    "$REPO/tools/fx-select.c" > "$WORK/fx-select-mutant2.c" || fail "S2: cannot write the mutant source"
cmp -s "$WORK/fx-select-mutant2.c" "$REPO/tools/fx-select.c" \
    && fail "S2: the coherence mutant is IDENTICAL to the seat — the sed matched nothing"
cc -std=c11 -O2 -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE -o "$WORK/fx-select-mutant2" \
    "$WORK/fx-select-mutant2.c" || fail "S2: the coherence mutant does not compile"
mrc=$(FXSTORE_BIN="$FXSTORE" "$WORK/fx-select-mutant2" $SEL2 > "$F2/o.s2mut" 2>&1; echo $?)
[ "$mrc" = "0" ] || fail "S2-mutant: expected exit 0, got $mrc"
[ "$(decision_kind "$F2/o.s2mut")" = "keep" ] \
    || fail "S2-mutant: the coherence-blind seat did NOT keep the drifting incumbent: $(grep -m1 '^decision' "$F2/o.s2mut")"
[ "$(decision_version "$F2/o.s2mut")" = "$F2_O_LAST" ] \
    || fail "S2-mutant: expected the coherence-blind seat to keep v$F2_O_LAST"
grep -q "^candidate	$F2_O_LAST	1	viability	ok	.*coherence	drift	.*eligible	yes" "$F2/o.s2mut" \
    || fail "S2-mutant: the mutant's own table does not show the drift it ranked past"
echo "test_fx_select: S2 MUTANT (coherence filter dropped) keeps the drifting incumbent v$F2_O_LAST; the seat reverts to v$w"

# ── S15: an EXCLUDED CHALLENGER blocks nothing (the mirror of S5a) ─────
# The challenger is the only generation that runs a component whose host tree
# no longer verifies, so the oracle refuses IT while the incumbent measures
# fine.  Rule 8: a candidate the oracle refuses cannot win — and unlike the
# incumbent case (S5a) it withholds nothing, because CURRENT is measured and
# remains the only eligible candidate.
# FAILING DIRECTION: a seat that treats any refusal as "cannot decide" would
# withhold (exit 3) instead of keeping the measured incumbent.
echo "/* mutated after activation: the oracle must REFUSE this tree */" >> "$F2/src/c-svc/main.c"
materialize_rootfs "$S2" "$F2/rootfs-clean" "$(current_of "$S2")"
SEL15="--store $S2 --rootfs $F2/rootfs-clean --fxstore $FXSTORE --oracle $OSIER --package-set $P2"
rc=$(run_select "$F2/o.s15" $SEL15)
[ "$rc" = "0" ] || fail "S15: expected exit 0, got $rc: $(grep -m1 '^decision' "$F2/o.s15")"
grep -q "^excluded	$F2_C_LAST	oracle-refused	" "$F2/o.s15" \
    || fail "S15: the refused CHALLENGER is not NAMED: $(grep '^excluded' "$F2/o.s15")"
[ "$(share_state_of "$F2/o.s15" "$F2_C_LAST")" = "oracle-refused" ] || fail "S15: the challenger is not in the oracle-refused state"
grep -q "^decision	keep	$F2_O_LAST	" "$F2/o.s15" \
    || fail "S15: an excluded challenger must not withhold the decision: $(grep -m1 '^decision' "$F2/o.s15")"
grep -q "^caveat	excluded-candidates	" "$F2/o.s15" || fail "S15: the excluded count is not printed"
echo "test_fx_select: S15 an excluded CHALLENGER (v$F2_C_LAST) is named and blocks nothing -> keep the measured incumbent v$F2_O_LAST"

# ═══ fix3 — order E OD O: a genuine TIE at the top share ═══════════════
build_fixture fix3 "E OD O"
F3="$WORK/fix3"; S3="$F3/store"; P3="$F3/package-set.dhall"
F3_D_LAST=$(act_last fix3 2); F3_O_LAST=$(act_last fix3 3)
[ "$(current_of "$S3")" = "$F3_O_LAST" ] || fail "fix3: CURRENT is not the last O version"
materialize_rootfs "$S3" "$F3/rootfs" "$(current_of "$S3")"
write_bootlog "$S3"
SEL3="--store $S3 --rootfs $F3/rootfs --fxstore $FXSTORE --oracle $OSIER --package-set $P3"
rc=$(run_select "$F3/o.s4" $SEL3)
[ "$rc" = "0" ] || fail "S4: expected exit 0, got $rc"
# the tie must be REAL: two CANDIDATES, both eligible, at the same measured share
tie=$(awk -F'\t' '$1=="candidate" && $22=="yes" && $19=="yes" && $9=="1.000000"' "$F3/o.s4" | wc -l | tr -d ' ')
[ "$tie" -ge 2 ] || fail "S4: the fixture does not produce a tied pair of candidates: $(grep '^candidate' "$F3/o.s4")"
grep -q "^candidate	$F3_O_LAST	1	viability	ok	.*share	1.000000	.*eligible	yes.*is-candidate	yes" "$F3/o.s4" \
    || fail "S4: the incumbent is not an eligible member of the tie"
# FAILING DIRECTION: a seat that reverts on a tie names the older twin (and
# the S4 mutant below is exactly that seat).
[ "$(decision_kind "$F3/o.s4")" = "keep" ] || fail "S4: a TIE caused a revert: $(grep -m1 '^decision' "$F3/o.s4")"
[ "$(decision_version "$F3/o.s4")" = "$F3_O_LAST" ] || fail "S4: expected keep $F3_O_LAST"
[ "$(expected_winner "$F3/o.s4")" = "$F3_O_LAST" ] || fail "S4: the table does not entail the keep"
echo "test_fx_select: S4 a tie at 1.000000 (v$F3_D_LAST vs CURRENT v$F3_O_LAST, both candidates) -> keep (no revert)"

# ── S4's PROOF THAT THE TIE RULE CAN FAIL: drop the incumbent clause ───
# `(s->share > best) || (s->share == best && I am the incumbent)` — remove the
# tie clause and the FIRST maximum in version order wins, i.e. the older twin.
sed 's/ || (s->share == g_share\[best\].share \&\& g_vers\[i\].is_current)//' \
    "$REPO/tools/fx-select.c" > "$WORK/fx-select-mutant3.c" || fail "S4: cannot write the tie mutant"
cmp -s "$WORK/fx-select-mutant3.c" "$REPO/tools/fx-select.c" \
    && fail "S4: the tie mutant is IDENTICAL to the seat — the sed matched nothing"
cc -std=c11 -O2 -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE -o "$WORK/fx-select-mutant3" \
    "$WORK/fx-select-mutant3.c" || fail "S4: the tie mutant does not compile"
mrc=$(FXSTORE_BIN="$FXSTORE" "$WORK/fx-select-mutant3" $SEL3 > "$F3/o.s4mut" 2>&1; echo $?)
[ "$mrc" = "0" ] || fail "S4-mutant: expected exit 0, got $mrc"
[ "$(decision_kind "$F3/o.s4mut")" = "revert-to" ] \
    || fail "S4-mutant: the tie-blind seat did NOT revert on the tie: $(grep -m1 '^decision' "$F3/o.s4mut")"
[ "$(decision_version "$F3/o.s4mut")" = "$F3_D_LAST" ] \
    || fail "S4-mutant: expected revert-to the older twin v$F3_D_LAST, got $(decision_version "$F3/o.s4mut")"
echo "test_fx_select: S4 MUTANT (tie clause dropped) reverts on the tie to v$F3_D_LAST; the seat keeps the incumbent v$F3_O_LAST"

# ── S4b: versions ABOVE CURRENT are outside the bound (a --hard repoint) ─
# `fxstore rollback --hard` repoints CURRENT with no new version, leaving the
# versions above it in the timeline.  Rule 1 bounds the set to the incumbent
# and the change it replaced, so they are named not-candidate/above-current.
# FAILING DIRECTION: the pre-fix seat treats v$F3_O_LAST (above CURRENT, tied
# on share) as a candidate and reverts FORWARD to it.
materialize_rootfs "$S3" "$F3/rootfs-hard" "$F3_D_LAST"
"$FXSTORE" rollback --hard "$F3_D_LAST" --store "$S3" >/dev/null 2>&1 \
    || fail "S4b: fxstore rollback --hard failed"
[ "$(current_of "$S3")" = "$F3_D_LAST" ] || fail "S4b: --hard did not repoint CURRENT"
rc=$(run_select "$F3/o.s4b" --store "$S3" --rootfs "$F3/rootfs-hard" --fxstore "$FXSTORE" --oracle "$OSIER" --package-set "$P3")
[ "$rc" = "0" ] || fail "S4b: expected exit 0, got $rc"
[ "$(is_cand "$F3/o.s4b" "$F3_O_LAST")" = "no" ] \
    || fail "S4b: a version ABOVE CURRENT is a candidate: $(grep "^candidate	$F3_O_LAST	" "$F3/o.s4b")"
case "$(nc_reason "$F3/o.s4b" "$F3_O_LAST")" in
    above-current*) ;;
    *) fail "S4b: its exclusion is not named as above-current: $(nc_reason "$F3/o.s4b" "$F3_O_LAST")";;
esac
[ "$(decision_version "$F3/o.s4b")" = "$F3_D_LAST" ] \
    || fail "S4b: expected the incumbent to be kept, got $(grep -m1 '^decision' "$F3/o.s4b")"
echo "test_fx_select: S4b after --hard to v$F3_D_LAST the version above it (v$F3_O_LAST) is not a candidate and cannot be reverted forward to"

# ═══ fix4 — order E O OC: withholding, exclusion, and the tool error ═══
build_fixture fix4 "E O OC"
F4="$WORK/fix4"; S4="$F4/store"; P4="$F4/package-set.dhall"
F4_C_LAST=$(act_last fix4 3)
materialize_rootfs "$S4" "$F4/rootfs" "$(current_of "$S4")"
SEL4="--store $S4 --rootfs $F4/rootfs --fxstore $FXSTORE --oracle $OSIER --package-set $P4"

# ── S5b: NO eligible candidate -> a NAMED refusal, non-zero exit ────────
# FAILING DIRECTION: a keep-by-default seat exits 0 with a decision the
# records do not support.
_allfail=""
for _v in $(versions_of "$S4"); do _allfail="$_allfail $_v:failed"; done
write_bootlog "$S4" $_allfail
rc=$(run_select "$F4/o.s5b" $SEL4)
[ "$rc" = "1" ] || fail "S5b: expected exit 1 (named refusal), got $rc: $(tail -3 "$F4/o.s5b")"
grep -q '^verdict	no-eligible-candidate' "$F4/o.s5b" || fail "S5b: no named no-eligible verdict"
grep -q "^decision	no-eligible-candidate	-	-	" "$F4/o.s5b" || fail "S5b: no named no-eligible decision record"
grep -q 'NO ELIGIBLE CANDIDATE' "$F4/o.s5b" || fail "S5b: the refusal is not loud in the human summary"
[ -z "$(decision_version "$F4/o.s5b")" ] || fail "S5b: a version was named anyway"
echo "test_fx_select: S5b no eligible candidate -> named refusal, exit $rc"

# ── S5a: an oracle-refusing INCUMBENT WITHHOLDS — never revert-to, and
#        the refusal is NAMED (rule 8). ────────────────────────────────
# Mutate a RUN component's host source tree: the oracle's clean-hash check
# refuses a tree that no longer matches the version-bound srcstore hash, and
# BOTH candidates (the incumbent and the generation it replaced) run it.
# FAILING DIRECTION: the pre-fix seat printed `decision revert-to <winner>`
# with exit 0 here — a decision resting on a comparison whose incumbent side
# was never measured — and a harness consuming the frozen record would act
# where --apply refuses.  A 0%-substituting seat names a version outright.
write_bootlog "$S4"
echo "/* mutated after activation: the oracle must REFUSE this tree */" >> "$F4/src/osier-svc/Main.elm"
h_before=$(store_hash "$S4")
rc=$(run_select "$F4/o.s5a" $SEL4)
[ "$rc" = "3" ] || fail "S5a: an unmeasurable incumbent must WITHHOLD (exit 3), got $rc: $(grep -m1 '^decision' "$F4/o.s5a")"
grep -q "^decision	withhold	-	current-unmeasured	" "$F4/o.s5a" \
    || fail "S5a: the withholding state is not the named one: $(grep -m1 '^decision' "$F4/o.s5a")"
grep -q '^decision	revert-to' "$F4/o.s5a" && fail "S5a: an unmeasured state was printed as revert-to"
nex=$(grep -c '^excluded	' "$F4/o.s5a")
[ "$nex" -ge 1 ] || fail "S5a: no candidate was excluded even though the oracle refuses the mutated tree"
grep -q "^excluded	$F4_C_LAST	oracle-refused	" "$F4/o.s5a" \
    || fail "S5a: the INCUMBENT's refusal is not NAMED: $(grep '^excluded' "$F4/o.s5a")"
grep -q "^caveat	excluded-candidates	$nex	" "$F4/o.s5a" \
    || fail "S5a: the excluded count is not printed as its own caveat line (rows=$nex): $(grep '^caveat.excluded' "$F4/o.s5a")"
grep -q "^candidate	$F4_C_LAST	1	.*share	-	share-state	oracle-refused" "$F4/o.s5a" \
    || fail "S5a: the refused incumbent does not read as UNMEASURED: $(grep "^candidate	$F4_C_LAST	1" "$F4/o.s5a")"
grep -q 'NEVER as `revert-to`' "$F4/o.s5a" || true
# and the trigger reads the SAME value: no mutation, same exit
rc=$(run_select "$F4/o.s5aa" $SEL4 --apply)
[ "$rc" = "3" ] || fail "S5a: --apply on a withheld decision must exit 3, got $rc"
grep -q '^apply	refused	withheld-current-unmeasured	' "$F4/o.s5aa" \
    || fail "S5a: --apply did not refuse the withheld incumbent: $(grep '^apply' "$F4/o.s5aa")"
grep -q '^SELECT	' "$F4/o.s5aa" && fail "S5a: a SELECT record was printed for a withheld decision"
[ "$h_before" = "$(store_hash "$S4")" ] || fail "S5a: the store changed under the withheld state"
echo "test_fx_select: S5a $nex candidate(s) excluded BY NAME (incl. the incumbent v$F4_C_LAST) -> withhold (exit 3), plain and --apply agree, store unchanged"

# ── S11: a missing oracle is a TOOL ERROR, never a 0% ──────────────────
rc=$(run_select "$F4/o.s11" --store "$S4" --rootfs "$F4/rootfs" --fxstore "$FXSTORE" \
        --oracle "$WORK/definitely-not-an-oracle" --package-set "$P4")
[ "$rc" = "2" ] || fail "S11: a missing oracle must be a TOOL ERROR (exit 2), got $rc: $(tail -2 "$F4/o.s11")"
grep -q 'cannot be run' "$F4/o.s11" || fail "S11: the tool error is not named: $(tail -2 "$F4/o.s11")"
grep -q '^decision' "$F4/o.s11" && fail "S11: a decision was produced off a missing oracle"
echo "test_fx_select: S11 a missing oracle -> exit 2, no decision, named"

echo "test_fx_select: PASS (the order is enforced: S1/S1-mutant, S2/S2-mutant, S3, S4/S4-mutant, S4b, S5a, S5b, S6, S7, S8a, S8b, S8c/S8d, S9, S10, S11, S12, S12b, S13, S15, S16, S17)"
exit 0
