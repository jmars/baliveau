#!/bin/sh
# tests/test_fx_select.sh — THE DISCRIMINATION PROOF for THE SELECTION STEP.
#
# tools/fx-select.c computes which generation the system SHOULD be running
# under the lexicographic order (viability -> coherence -> maximise the
# Osier share) and ENFORCES it.  A seat whose order can be printed and
# ignored would pass a shape test and fail its purpose, so every arm below
# is written with its FAILING DIRECTION named: each one is a scene in which
# the WRONG implementation (rank by share alone; always keep the newest;
# revert on a tie; count an unmeasurable candidate as 0%; act without
# --apply) answers DIFFERENTLY.  The headline arm additionally proves the
# arm CAN fail, by mutating the seat (drop the viability filter) and showing
# the mutant goes blind on EXACTLY that fixture.
#
#   S1  HEADLINE: the highest-share generation FAILED its boot -> the
#       decision must NOT name it.  FAILING DIRECTION: a seat that ranks by
#       share alone names the failed 1.000000 generation (the sed-mutant in
#       this file is exactly that seat and is asserted to name it).
#   S2  the highest-share VIABLE candidate is CURRENT and DRIFTS -> not
#       eligible; a lower-share viable generation wins.  FAILING DIRECTION:
#       a seat that measures coherence after the share, or not at all, keeps
#       the drifting CURRENT.
#   S3  among eligible candidates the MAX share wins, not the newest.
#       FAILING DIRECTION: "always keep the newest" / "rank by version" both
#       return keep, and this arm returns revert-to an OLDER version.
#   S4  a TIE does not cause a revert (keep <CURRENT>).
#   S4b the tie rule is LIVE, not inert: with CURRENT moved (by
#       `fxstore rollback --hard`) to the LOWER version of a tied pair, the
#       same rule selects the HIGHER one.  FAILING DIRECTION: "always keep
#       CURRENT" passes S4 and fails S4b.
#   S5a an oracle-REFUSING candidate is EXCLUDED BY NAME, never counted as
#       0%.  FAILING DIRECTION: a 0%-substituting seat lets the tie rule
#       pick the *excluded* (highest-version) candidate.
#   S5b NO eligible candidate -> a NAMED refusal and a NON-ZERO exit.
#       FAILING DIRECTION: a seat that keeps-by-default exits 0 with a
#       decision the records do not support.
#   S6  THE DEFAULT NEVER MUTATES: the store's records hash identically
#       before and after a plain (non-apply) run.
#   S7  determinism: two runs are cmp-identical.
#   S8a --apply whose decision is `keep` REFUSES (exit 0, no rollback, the
#       store byte-unchanged).  FAILING DIRECTION: a trigger that fires on
#       every run dresses a no-op as an action.
#   S8b --apply whose winner is older LANDS, by asymmetry (the pre-apply
#       store did not hold the new version) and with the VERSION NUMBER
#       INCREASED — the soft-rollback semantics the seat claims.
#   S9  the order table prints on every run (the rule is auditable).
#   S10 the 3-field LEGACY .bootlog shape is tolerated with its meaning
#       stated (the order table says what it is) — gated, not just claimed.
#   S11 a missing oracle is a TOOL ERROR (exit 2), never a 0%.
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
# SIBLING RESOLUTION — deliberately NOT the stale `$REPO/..` default the
# ten older gates use: after the move to ~/futaie/baliveau, `$REPO/..` is
# ~/futaie, which contains no fx-init/fxstore/datalog-dafsa, so those gates
# SKIP on this host (MEASURED: `make test-osier-share` skips at "libdatalog.so
# missing at /home/jaye/futaie/datalog-dafsa/zig-out/lib").  Order here:
# (1) $FX_INIT_REPO / $FXSTORE_BIN from the env; (2) $REPO/.. IF it really
# contains fx-init; (3) $FX_SIBLINGS, default $HOME/fixpoint-linux;
# (4) otherwise SKIP loudly.
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

# ── sibling resolution (see the header) ─────────────────────────────────
SIBS=""
if [ -d "$REPO/../fx-init" ]; then
    SIBS="$(cd "$REPO/.." && pwd)"
elif [ -n "${FX_SIBLINGS:-}" ] && [ -d "$FX_SIBLINGS/fx-init" ]; then
    SIBS="$FX_SIBLINGS"
elif [ -d "$HOME/fixpoint-linux/fx-init" ]; then
    SIBS="$HOME/fixpoint-linux"
else
    skip "no fx-init checkout in \$REPO/.., \$FX_SIBLINGS or \$HOME/fixpoint-linux (set FX_SIBLINGS)"
fi
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
max_viable_share() {
    awk -F'\t' '$1=="candidate" && $5=="ok" {s=$9+0; if(!got||s>m){m=s;got=1}}
                 END{if(got)printf "%.6f\n",m}' "$1"
}
expected_winner() {
    awk -F'\t' '$1=="candidate" && $19=="yes" {
                    v=$2+0; sh=$9+0;
                    if (!got || sh>bs || (sh==bs && v>bv)) { got=1; bs=sh; bv=v }
                 }
                 END { if (got) print bv }' "$1"
}

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

# ═══ ARM S1 + S3 + S6 + S7 + S9 + S10 + S8a + S8b — order E O OC ════════
echo "== fixtures"
build_fixture fix1 "E O OC"
F1="$WORK/fix1"; S1="$F1/store"; P1="$F1/package-set.dhall"
F1_O_FIRST=$(act_first fix1 2); F1_O_LAST=$(act_last fix1 2)
F1_C_FIRST=$(act_first fix1 3); F1_C_LAST=$(act_last fix1 3)
echo "test_fx_select: fix1 E/$(act_last fix1 1)  O/$F1_O_FIRST-$F1_O_LAST  OC/$F1_C_FIRST-$F1_C_LAST (CURRENT)"
[ "$(current_of "$S1")" = "$F1_C_LAST" ] || fail "fix1: CURRENT is not the last OC version"

materialize_rootfs "$S1" "$F1/rootfs" "$(current_of "$S1")"

SEL="--store $S1 --rootfs $F1/rootfs --fxstore $FXSTORE --oracle $OSIER --package-set $P1"

# ── S9: the order table prints on every run (the rule is auditable) ─────
write_bootlog "$S1"
h_before=$(store_hash "$S1")
rc=$(run_select "$F1/o.s9" $SEL)
[ "$rc" = "0" ] || fail "S9: expected exit 0, got $rc: $(sed -n 1,5p "$F1/o.s9")"
grep -q '^order	1	candidates	' "$F1/o.s9" || fail "S9: the frozen order table is not in the output"
grep -q '^order	8	apply	' "$F1/o.s9" || fail "S9: the apply step of the order is not printed"
grep -q '^bound	share-of-a-partial-snapshot	' "$F1/o.s9" || fail "S9: the bounds table is not printed"
for _n in 1 2 3 4 5 6 7 8; do
    grep -q "^order	$_n	" "$F1/o.s9" || fail "S9: order step $_n missing"
done
echo "test_fx_select: S9 the order table (8 steps) + bounds print on every run"

# ── S3: the MAX share wins among eligible candidates, not the newest ────
# FAILING DIRECTION: "always keep the newest" returns keep; this arm must
# return revert-to an OLDER version with the greater share.
ckind=$(decision_kind "$F1/o.s9"); cver=$(decision_version "$F1/o.s9")
[ "$ckind" = "revert-to" ] || fail "S3: expected revert-to, got '$ckind': $(grep -m1 '^decision' "$F1/o.s9")"
[ "$cver" != "$F1_C_LAST" ] || fail "S3: the newest generation held the LOWER share, so a keep is the wrong answer: $(grep -m1 '^decision' "$F1/o.s9")"
[ "$cver" = "$(expected_winner "$F1/o.s9")" ] \
    || fail "S3: the decision (v$cver) is not the choice the printed table entails (v$(expected_winner "$F1/o.s9"))"
grep -q "^candidate	$cver	0	viability	ok	.*share-state	measured	.*eligible	yes" "$F1/o.s9" \
    || fail "S3: the winner's row is not a measured, eligible row: $(grep "^candidate	$cver	" "$F1/o.s9")"
grep -q "^candidate	$F1_C_LAST	1	viability	ok	.*share-state	measured" "$F1/o.s9" \
    || fail "S3: CURRENT is not a measured, viable row: $(grep "^candidate	$F1_C_LAST	1" "$F1/o.s9")"
w_share=$(share_of "$F1/o.s9" "$cver"); cur_share=$(share_of "$F1/o.s9" "$F1_C_LAST")
fgt "$w_share" "$cur_share" "S3: the winner's share $w_share does not exceed CURRENT's $cur_share"
echo "test_fx_select: S3 max share wins over newest (revert-to v$cver at $w_share, CURRENT v$F1_C_LAST holds $cur_share)"

# ── S6: THE DEFAULT NEVER MUTATES ───────────────────────────────────────
rc=$(run_select "$F1/o.s6" $SEL)
[ "$rc" = "0" ] || fail "S6: expected exit 0, got $rc"
h_after=$(store_hash "$S1")
[ "$h_before" = "$h_after" ] || fail "S6: a plain run MUTATED the store ($h_before -> $h_after)"
cmp -s "$F1/o.s6" "$F1/o.s9" || fail "S6/S7: the second plain run's output differs from the first"
# ── S7: determinism, stated as its own arm ──────────────────────────────
rc=$(run_select "$F1/o.s7" $SEL)
[ "$rc" = "0" ] || fail "S7: expected exit 0, got $rc"
cmp -s "$F1/o.s6" "$F1/o.s7" || fail "S7: two runs over the same store are not byte-identical"
echo "test_fx_select: S6 no mutation without --apply; S7 two runs cmp-identical"

# ── S1 THE HEADLINE: the highest-share generation FAILED its boot ───────
# FAILING DIRECTION: a seat that ranks by share alone names the failed
# 1.000000 generation (proved by the mutant below).
write_bootlog "$S1" "$F1_O_FIRST:failed" "$F1_O_LAST:failed" "$F1_C_FIRST:failed"
# the premise, measured on the seat's own table: every candidate holding the
# greatest share is a FAILED one
# (the premise is asserted below, version by version)
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
grep -q "^decision	revert-to" "$F1/o.s1" && fail "S1: the seat reverted to a generation whose boot FAILED: $(grep -m1 '^decision' "$F1/o.s1")"
[ "$cver" = "$(expected_winner "$F1/o.s1")" ] || fail "S1: the decision disagrees with the seat's own table"
[ "$(expected_winner "$F1/o.s1")" != "$F1_O_LAST" ] || fail "S1: the table itself names the failed generation"
echo "test_fx_select: S1 the failed highest-share generation ($F1_O_LAST) is not named -> keep $cver"

# ── S1's PROOF THAT THE ARM CAN FAIL: the sed-mutant ────────────────────
# Drop the viability filter (rank by share alone) and rebuild.  The mutant
# must go blind on EXACTLY the S1 fixture: it names the failed generation.
sed 's/int eligible = viable && coherent && s->measured;/int eligible = coherent \&\& s->measured;/' \
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
# the mutant must name a generation that FAILED its boot: its own table
# shows the verdict it ranked past
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
    || fail "S10: the 3-field legacy verdict is not read as a verdict: $(grep "^candidate	$F1_O_LAST" "$F1/o.s10")"
[ "$(decision_kind "$F1/o.s10")" = "keep" ] || fail "S10: the legacy shape changed the decision"
echo "test_fx_select: S10 the 3-field pre-nonce verdict shape is read (and named as such)"

# ── S8a: --apply where CURRENT IS the winner -> refuses, no mutation ───
h_before=$(store_hash "$S1"); v_before=$(versions_of "$S1")
rc=$(run_select "$F1/o.s8a" $SEL --apply)
[ "$rc" = "0" ] || fail "S8a: a keep under --apply must exit 0, got $rc: $(grep -m1 '^apply' "$F1/o.s8a")"
grep -q "^apply	refused	current-already-the-winner" "$F1/o.s8a" \
    || fail "S8a: no named refusal for a no-op: $(grep '^apply' "$F1/o.s8a")"
grep -q "^decision	keep	$F1_C_LAST	" "$F1/o.s8a" || fail "S8a: the decision is not keep $F1_C_LAST"
h_after=$(store_hash "$S1")
[ "$h_before" = "$h_after" ] || fail "S8a: --apply on a keep MUTATED the store"
[ "$(versions_of "$S1")" = "$v_before" ] || fail "S8a: --apply on a keep published a version"
echo "test_fx_select: S8a --apply on a keep refuses (exit 0), store byte-unchanged, no new version"

# ── S8b: --apply where the winner is OLDER -> the rollback LANDS ───────
write_bootlog "$S1"
pre_current=$(current_of "$S1"); pre_versions=$(versions_of "$S1")
rc=$(run_select "$F1/o.s8b" $SEL --apply)
[ "$rc" = "0" ] || fail "S8b: expected exit 0, got $rc: $(grep '^apply' "$F1/o.s8b")"
w8=$(decision_version "$F1/o.s8b")
[ "$w8" != "$pre_current" ] || fail "S8b: the winner is CURRENT, so --apply should have refused"
[ "$w8" = "$(expected_winner "$F1/o.s8b")" ] || fail "S8b: the decision v$w8 disagrees with the table v$(expected_winner "$F1/o.s8b")"
grep -q "^apply	done	soft-rollback	from	$pre_current	to	$w8	" "$F1/o.s8b" \
    || fail "S8b: no soft-rollback record naming the move: $(grep '^apply' "$F1/o.s8b")"
grep -q '^# SELECT: ' "$F1/o.s8b" || fail "S8b: no loud SELECT line naming what caused the rollback"
post_current=$(current_of "$S1"); post_versions=$(versions_of "$S1")
# asymmetry: the pre-apply store did not hold the post-apply CURRENT
case " $pre_versions " in *" $post_current "*) fail "S8b: the post-apply CURRENT $post_current already existed before --apply — nothing landed";; esac
[ "$post_current" -gt "$pre_current" ] \
    || fail "S8b: the SOFT rollback did not raise the version number ($pre_current -> $post_current)"
grep -q "^apply	done	soft-rollback	from	$pre_current	to	$w8	new-current	$post_current	version-increased	yes" "$F1/o.s8b" \
    || fail "S8b: the seat did not report the version increase it relies on"
echo "test_fx_select: S8b --apply lands: CURRENT $pre_current -> $post_current (soft, version INCREASED; pre-apply store held neither)"

# ═══ ARM S2 — order E OC O: CURRENT has the top share and DRIFTS ═══════
build_fixture fix2 "E OC O"
F2="$WORK/fix2"; S2="$F2/store"; P2="$F2/package-set.dhall"
F2_C_LAST=$(act_last fix2 2); F2_O_LAST=$(act_last fix2 3)
[ "$(current_of "$S2")" = "$F2_O_LAST" ] || fail "fix2: CURRENT is not the last O version"
materialize_rootfs "$S2" "$F2/rootfs" "$(current_of "$S2")"
echo "payload" > "$F2/rootfs/bin/rogue"        # an unmanaged rootfs file (test_fx_audit.sh's drift shape)
"$FXSTORE" verify "$F2/rootfs" --as-of "$(current_of "$S2")" --store "$S2" >/dev/null 2>&1 \
    && fail "S2: precondition: the fixture rootfs is not drifting"
write_bootlog "$S2"
rc=$(run_select "$F2/o.s2" --store "$S2" --rootfs "$F2/rootfs" --fxstore "$FXSTORE" --oracle "$OSIER" --package-set "$P2")
[ "$rc" = "0" ] || fail "S2: expected exit 0, got $rc"
# FAILING DIRECTION: a seat that measures coherence after (or not at all)
# would keep the drifting CURRENT, which holds the greatest share here.
grep -q "^candidate	$F2_O_LAST	1	viability	ok	.*coherence	drift	.*eligible	no" "$F2/o.s2" \
    || fail "S2: the drifting CURRENT is not marked drift/not-eligible: $(grep "^candidate	$F2_O_LAST	1" "$F2/o.s2")"
# the fixture's premise: CURRENT holds the GREATEST share among viable
# candidates (so a share-first seat would keep it) and it DRIFTS
cur_share=$(share_of "$F2/o.s2" "$F2_O_LAST")
mvs=$(max_viable_share "$F2/o.s2")
[ -n "$cur_share" ] || fail "S2: CURRENT is not in the table"
feq "$cur_share" "$mvs" "S2: fixture premise broken — CURRENT holds $cur_share but the greatest viable share is $mvs (the arm's whole point is a max-share CURRENT)"
[ "$(decision_kind "$F2/o.s2")" = "revert-to" ] || fail "S2: expected revert-to a viable lower-share generation: $(grep -m1 '^decision' "$F2/o.s2")"
w=$(decision_version "$F2/o.s2")
[ "$w" != "$F2_O_LAST" ] || fail "S2: the decision kept the DRIFTING CURRENT"
[ "$w" = "$(expected_winner "$F2/o.s2")" ] || fail "S2: the decision v$w disagrees with the table v$(expected_winner "$F2/o.s2")"
grep -q "^candidate	$w	0	viability	ok	.*eligible	yes" "$F2/o.s2" \
    || fail "S2: the winner v$w is not a viable eligible generation: $(grep "^candidate	$w	" "$F2/o.s2")"
flt "$(share_of "$F2/o.s2" "$w")" "$cur_share" "S2: the winner v$w does not hold a LOWER share than the drifting CURRENT ($cur_share)"
grep -q '^verdict	revert-to' "$F2/o.s2" || fail "S2: no revert-to verdict"
other="$w"
grep -q "^drift	$F2_O_LAST	" "$F2/o.s2" || fail "S2: the drift is not reported as its own record"
echo "test_fx_select: S2 a drifting CURRENT ($F2_O_LAST) is not eligible; the lower-share v$other wins"

# ── S2's PROOF THAT THE ARM CAN FAIL: drop the COHERENCE filter ────────
# The other load-bearing term.  A seat that ranks viable candidates by share
# alone keeps the drifting CURRENT here.
sed 's/int eligible = viable && coherent && s->measured;/int eligible = viable \&\& s->measured;/' \
    "$REPO/tools/fx-select.c" > "$WORK/fx-select-mutant2.c" || fail "S2: cannot write the mutant source"
cmp -s "$WORK/fx-select-mutant2.c" "$REPO/tools/fx-select.c" \
    && fail "S2: the coherence mutant is IDENTICAL to the seat — the sed matched nothing"
cc -std=c11 -O2 -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE -o "$WORK/fx-select-mutant2" \
    "$WORK/fx-select-mutant2.c" || fail "S2: the coherence mutant does not compile"
mrc=$(FXSTORE_BIN="$FXSTORE" "$WORK/fx-select-mutant2" \
        --store "$S2" --rootfs "$F2/rootfs" --fxstore "$FXSTORE" --oracle "$OSIER" --package-set "$P2" \
        > "$F2/o.s2mut" 2>&1; echo $?)
[ "$mrc" = "0" ] || fail "S2-mutant: expected exit 0, got $mrc"
[ "$(decision_kind "$F2/o.s2mut")" = "keep" ] \
    || fail "S2-mutant: the coherence-blind seat did NOT keep the drifting CURRENT: $(grep -m1 '^decision' "$F2/o.s2mut")"
[ "$(decision_version "$F2/o.s2mut")" = "$F2_O_LAST" ] \
    || fail "S2-mutant: expected the coherence-blind seat to keep v$F2_O_LAST"
grep -q "^candidate	$F2_O_LAST	1	viability	ok	.*coherence	drift	.*eligible	yes" "$F2/o.s2mut" \
    || fail "S2-mutant: the mutant's own table does not show the drift it ranked past"
echo "test_fx_select: S2 MUTANT (coherence filter dropped) keeps the drifting CURRENT v$F2_O_LAST; the seat reverts to v$other"

# ═══ ARM S4 / S4b — order E OD O: a genuine TIE at the top share ═══════
build_fixture fix3 "E OD O"
F3="$WORK/fix3"; S3="$F3/store"; P3="$F3/package-set.dhall"
F3_D_LAST=$(act_last fix3 2); F3_O_LAST=$(act_last fix3 3)
[ "$(current_of "$S3")" = "$F3_O_LAST" ] || fail "fix3: CURRENT is not the last O version"
materialize_rootfs "$S3" "$F3/rootfs" "$(current_of "$S3")"
write_bootlog "$S3"
rc=$(run_select "$F3/o.s4" --store "$S3" --rootfs "$F3/rootfs" --fxstore "$FXSTORE" --oracle "$OSIER" --package-set "$P3")
[ "$rc" = "0" ] || fail "S4: expected exit 0, got $rc"
# the tie must be REAL: two eligible candidates at the SAME measured share
tie=$(grep -c "^candidate	[0-9]*	0	viability	ok	.*share	1.000000	.*eligible	yes" "$F3/o.s4")
[ "$tie" -ge 1 ] || fail "S4: the fixture does not produce a tied older candidate: $(grep '^candidate' "$F3/o.s4")"
grep -q "^candidate	$F3_O_LAST	1	viability	ok	.*share	1.000000	.*eligible	yes" "$F3/o.s4" \
    || fail "S4: CURRENT is not an eligible member of the tie"
# FAILING DIRECTION: a seat that reverts on a tie names the older twin.
[ "$(decision_kind "$F3/o.s4")" = "keep" ] || fail "S4: a TIE caused a revert: $(grep -m1 '^decision' "$F3/o.s4")"
[ "$(decision_version "$F3/o.s4")" = "$F3_O_LAST" ] || fail "S4: expected keep $F3_O_LAST"
[ "$(expected_winner "$F3/o.s4")" = "$F3_O_LAST" ] || fail "S4: the table does not entail the keep"
echo "test_fx_select: S4 a tie at 1.000000 (v$F3_D_LAST vs CURRENT v$F3_O_LAST) -> keep (no revert)"

# ── S4b: the tie rule is LIVE — with CURRENT at the LOWER twin ─────────
# Move CURRENT back with the substrate's own recovery-only --hard, re-
# materialize the rootfs for the new incumbent, and the SAME rule must now
# select the HIGHER twin.  FAILING DIRECTION: "always keep CURRENT" passes
# S4 and fails here; that is why this arm exists.
materialize_rootfs "$S3" "$F3/rootfs-hard" "$F3_D_LAST"
"$FXSTORE" rollback --hard "$F3_D_LAST" --store "$S3" >/dev/null 2>&1 \
    || fail "S4b: fxstore rollback --hard failed"
[ "$(current_of "$S3")" = "$F3_D_LAST" ] || fail "S4b: --hard did not repoint CURRENT"
rc=$(run_select "$F3/o.s4b" --store "$S3" --rootfs "$F3/rootfs-hard" --fxstore "$FXSTORE" --oracle "$OSIER" --package-set "$P3")
[ "$rc" = "0" ] || fail "S4b: expected exit 0, got $rc"
grep -q "^candidate	$F3_D_LAST	1	viability	ok	.*eligible	yes" "$F3/o.s4b" \
    || fail "S4b: the new incumbent is not eligible/coherent: $(grep "^candidate	$F3_D_LAST	1" "$F3/o.s4b")"
[ "$(decision_kind "$F3/o.s4b")" = "revert-to" ] || fail "S4b: the tie was not resolved toward the higher version: $(grep -m1 '^decision' "$F3/o.s4b")"
[ "$(decision_version "$F3/o.s4b")" = "$F3_O_LAST" ] \
    || fail "S4b: expected the higher twin $F3_O_LAST, got $(decision_version "$F3/o.s4b")"
[ "$(expected_winner "$F3/o.s4b")" = "$F3_O_LAST" ] || fail "S4b: the table does not entail the higher twin"
echo "test_fx_select: S4b with CURRENT at the lower twin v$F3_D_LAST the tie resolves to the HIGHER v$F3_O_LAST"

# ═══ ARM S5b (no eligible) + S5a (excluded by name) — order E O OC ═════
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
grep -q '^decision	no-eligible-candidate' "$F4/o.s5b" || fail "S5b: no named no-eligible decision record"
grep -q 'NO ELIGIBLE CANDIDATE' "$F4/o.s5b" || fail "S5b: the refusal is not loud in the human summary"
[ -z "$(decision_version "$F4/o.s5b")" ] || fail "S5b: a version was named anyway"
echo "test_fx_select: S5b no eligible candidate -> named refusal, exit $rc"

# ── S5a: an oracle-REFUSING candidate is EXCLUDED BY NAME, never 0% ────
# Mutate a RUN component's host source tree (the oracle's clean-hash check
# refuses a tree that no longer matches the version-bound srcstore hash).
# FAILING DIRECTION: a 0%-substituting seat would let the tie rule pick the
# EXCLUDED (highest-version) candidate, because every unmeasurable
# candidate would read as 0.000000 and the highest version would win.
write_bootlog "$S4"
echo "/* mutated after activation: the oracle must REFUSE this tree */" >> "$F4/src/osier-svc/Main.elm"
rc=$(run_select "$F4/o.s5a" $SEL4)
[ "$rc" = "0" ] || fail "S5a: expected exit 0, got $rc: $(tail -3 "$F4/o.s5a")"
nex=$(grep -c '^excluded	' "$F4/o.s5a")
[ "$nex" -ge 1 ] || fail "S5a: no candidate was excluded even though the oracle refuses the mutated tree"
grep -q "^excluded	$F4_C_LAST	oracle-refused	" "$F4/o.s5a" \
    || fail "S5a: the CURRENT candidate's refusal is not NAMED: $(grep '^excluded' "$F4/o.s5a")"
grep -q "^caveat	excluded-candidates	$nex	" "$F4/o.s5a" \
    || fail "S5a: the excluded count is not printed as its own caveat line (rows=$nex): $(grep '^caveat.excluded' "$F4/o.s5a")"
grep -q "^candidate	$F4_C_LAST	1	.*share	-	share-state	oracle-refused" "$F4/o.s5a" \
    || fail "S5a: the refused CURRENT does not read as UNMEASURED: $(grep "^candidate	$F4_C_LAST	1" "$F4/o.s5a")"
w=$(decision_version "$F4/o.s5a")
[ -n "$w" ] || fail "S5a: no decision"
grep -q "^excluded	$w	" "$F4/o.s5a" && fail "S5a: the decision named an EXCLUDED candidate (v$w) — an unmeasurable candidate was ranked"
[ "$w" = "$(expected_winner "$F4/o.s5a")" ] || fail "S5a: the decision ($w) disagrees with the table ($(expected_winner "$F4/o.s5a"))"
grep -q "^candidate	$w	[01]	viability	ok	.*share	0.000000	share-state	measured" "$F4/o.s5a" \
    || fail "S5a: the winner is not a MEASURED 0.000000 candidate: $(grep "^candidate	$w	" "$F4/o.s5a")"
echo "test_fx_select: S5a $nex candidate(s) excluded BY NAME (incl. CURRENT v$F4_C_LAST); the decision names v$w, none of them"

# ═══ ARM S11 — a missing oracle is a TOOL ERROR, never a 0% ════════════
rc=$(run_select "$F4/o.s11" --store "$S4" --rootfs "$F4/rootfs" --fxstore "$FXSTORE" \
        --oracle "$WORK/definitely-not-an-oracle" --package-set "$P4")
[ "$rc" = "2" ] || fail "S11: a missing oracle must be a TOOL ERROR (exit 2), got $rc: $(tail -2 "$F4/o.s11")"
grep -q 'cannot be run' "$F4/o.s11" || fail "S11: the tool error is not named: $(tail -2 "$F4/o.s11")"
grep -q '^decision' "$F4/o.s11" && fail "S11: a decision was produced off a missing oracle"
echo "test_fx_select: S11 a missing oracle -> exit 2, no decision, named"

echo "test_fx_select: PASS (the order is enforced: S1/S1-mutant, S2/S2-mutant, S3, S4, S4b, S5a, S5b, S6, S7, S8a, S8b, S9, S10, S11)"
exit 0
