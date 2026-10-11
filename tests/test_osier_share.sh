#!/bin/sh
# tests/test_osier_share.sh — THE DISCRIMINATION PROOF for the first oracle.
#
# A METRIC THAT READS 0 FOREVER PROVES NOTHING, so this gate must MOVE the
# number with a SYNTHETIC component it builds itself, and must show the two
# ways the number must NOT move:
#
#   A1 MOVES        adding an Osier-sourced component the generation RUNS
#                   raises the run-set share 0 -> non-zero (the todo.md
#                   "0% -> non-zero" first-self-modification shape).
#   A2 DEAD-CODE    adding an Osier-sourced component that is BUILT but NOT
#                   RUN leaves the run-set share EXACTLY unchanged (this is
#                   the property that kills dead-code inflation — if it
#                   moves, the oracle is counting the closure and the
#                   objective is wrong), while the CLOSURE share (printed
#                   for comparison, never averaged in) DOES move: the two
#                   numbers are shown to be genuinely different
#                   measurements, and the objective is the immune one.
#   A3 NON-OSIER    adding a RUN component whose source is NOT Osier does
#                   not raise the share: the numerator (osier bytes) is
#                   invariant, only the denominator grows.
#
# Plus the refusal seat (an oracle that guesses instead of refusing is
# worse than no oracle): an unreadable store, a nonexistent --as-of, and a
# RUN component whose only source is a MUTATED host tree (clean-hash no
# longer equals the version-bound srcstore hash) must each FAIL loudly —
# never print a 0%.
#
# Plus the origin split: the fixture materializes the clean-source artifact
# for ONE component (origin "store") and leaves another on the host-tree
# fallback (origin "host-verified") — the fallback passing at all PROVES
# this tool's C reimplementation of fxstore's fx_content_hash_dir agrees
# with the Zig original on that tree (a mismatch would refuse, not accept).
#
# The fixture store is provisioned TOOLCHAIN-FREE exactly like
# tests/qemu-agent-observe.sh:270-300 (activate_paths computes the closure
# and prints <hash>-<name>; the test pre-creates each dir; the REAL
# fx-activate then runs HOST-SIDE and writes the version-bound facts —
# provides/svc_bin/install AND the srcstore rows activate_paths never
# writes).  Nothing boots; nothing compiles; the recipes never run.
#
# Env: FX_SIBLINGS (default $HOME/fixpoint-linux unless $REPO/.. holds the
#      stack), FXSTORE_BIN (default $FX_SIBLINGS/fxstore/zig-out/bin/fxstore),
#      FX_INIT_REPO, OSIER_KEEP=1.
set -u

fail() { echo "test_osier_share: FAIL: $*" >&2; exit 1; }
skip() { echo "test_osier_share: SKIP ($*)"; exit 77; }

cd "$(dirname "$0")/.." || fail "cannot cd to repo root"
REPO="$PWD"
# Sibling root: an explicit FX_SIBLINGS wins; else the historical neighbour
# $REPO/.. only if it actually holds the stack (fx-init present); else the
# relocated default $HOME/fixpoint-linux.
SIBS="${FX_SIBLINGS:-$(cd "$REPO/.." && pwd)}"
[ -d "$SIBS/fx-init" ] || [ -n "${FX_SIBLINGS:-}" ] || SIBS="$HOME/fixpoint-linux"

command -v cc >/dev/null 2>&1 || skip "cc not found"
command -v wc >/dev/null 2>&1 || skip "wc not found"

FXSTORE="${FXSTORE_BIN:-$SIBS/fxstore/zig-out/bin/fxstore}"
[ -x "$FXSTORE" ] || skip "fxstore binary missing at $FXSTORE (set FX_SIBLINGS or FXSTORE_BIN, or build the sibling)"
"$FXSTORE" --help 2>&1 | grep -q 'fxstore facts' || skip "fxstore at $FXSTORE predates 'facts' (rebuild the sibling)"

INIT="${FX_INIT_REPO:-$SIBS/fx-init}"
[ -d "$INIT" ] || skip "fx-init checkout not found at $INIT (set FX_SIBLINGS or FX_INIT_REPO)"
DL="$SIBS/datalog-dafsa/zig-out/lib"
[ -f "$DL/libdatalog.so" ] || skip "libdatalog.so missing at $DL (set FX_SIBLINGS)"

# fx-init's x86_64 binaries: activate_paths + fx-activate, host-runnable
# (the qemu-agent-observe.sh guest-payload build, reused verbatim).
ZB="$REPO/build/guest-payload/init-x86_64-musl/bin"
if [ ! -x "$ZB/activate_paths" ] || [ ! -x "$ZB/fx-activate" ]; then
    command -v zig >/dev/null 2>&1 || skip "$ZB binaries absent and zig not found to build them"
    echo "test_osier_share: building fx-init's binaries (x86_64-linux-musl)"
    ( cd "$INIT/zig" && zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe \
        -p "$REPO/build/guest-payload/init-x86_64-musl" \
        --cache-dir "$REPO/build/guest-payload/zig-init-cache" ) || fail "fx-init zig build failed"
fi
[ -x "$ZB/activate_paths" ] || fail "no $ZB/activate_paths"
[ -x "$ZB/fx-activate" ] || fail "no $ZB/fx-activate"

# ── the NEW pair is REQUIRED: the fixture drives whatever binaries the
# staging holds, and the staging is a CACHE — a build from before src_of
# landed would silently drive the OLD writer and the resolution arms below
# would fail for the wrong reason (or worse, skip their premises).  Probe
# the CAPABILITY, not a ref: the fxstore must know the src_of relation, and
# the staged fx-activate must carry the writer that commits it.
grep -aq src_of "$ZB/fx-activate" || {
    skip "staged fx-activate at $ZB predates src_of — the staging froze on an OLD fx-init; rm -rf build/guest-payload/init-x86_64-musl and re-run to rebuild it"
}

# ── the OLD-writer control (PINNED fx-init revision, never its HEAD): the
#    ambiguity REFUSAL must still fire on a store whose activations predate
#    the src_of fact.  Same discipline as every pin in this repo: a FIXED
#    revision, a cat-file guard, and a cmp proof that the pinned
#    activate.zig DIFFERS from the working tree (identical would compare the
#    code to itself and prove nothing).  The pinned tree sits DIRECTLY under
#    $SIBS as a dot-dir (fx-init's build.zig resolves siblings as ../..),
#    shared with fx-init's own probe-src-of.sh.
OLD_INIT_REV="2feedf6"     # fx-init @ activate.zig WITHOUT src_of
OLD_INIT_SRC="$SIBS/.probe-pin-init-$OLD_INIT_REV"
OLD_INIT_OUT="$REPO/build/pin-init-$OLD_INIT_REV"
HAVE_OLD_WRITER=0
if git -C "$INIT" cat-file -e "$OLD_INIT_REV^{commit}" 2>/dev/null; then
    if [ ! -f "$OLD_INIT_SRC/zig/src/activate.zig" ]; then
        rm -rf "$OLD_INIT_SRC"; mkdir -p "$OLD_INIT_SRC"
        git -C "$INIT" archive "$OLD_INIT_REV" | tar -x -C "$OLD_INIT_SRC" \
            || fail "cannot extract fx-init $OLD_INIT_REV"
    fi
    if cmp -s "$OLD_INIT_SRC/zig/src/activate.zig" "$INIT/zig/src/activate.zig"; then
        skip "pinned $OLD_INIT_REV activate.zig is IDENTICAL to the working fx-init — the old-writer arm would compare the code to itself (fx-init's HEAD is not post-src_of?)"
    fi
    if [ ! -x "$OLD_INIT_OUT/bin/fx-activate" ] || [ ! -x "$OLD_INIT_OUT/bin/activate_paths" ]; then
        command -v zig >/dev/null 2>&1 \
            || skip "old-writer arm: pinned binaries absent and zig not found to build them"
        echo "test_osier_share: building the pinned OLD writer (fx-init $OLD_INIT_REV)"
        ( cd "$OLD_INIT_SRC/zig" && zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe \
            -p "$OLD_INIT_OUT" --cache-dir "$OLD_INIT_OUT-cache" ) \
            || fail "zig build of pinned fx-init $OLD_INIT_REV failed"
    fi
    HAVE_OLD_WRITER=1
else
    echo "test_osier_share: SKIP (old-writer arm): fx-init revision $OLD_INIT_REV unavailable (shallow clone?)"
fi

# the oracle itself (built by the Makefile target that runs this script)
OSIER="${OSIER_BIN:-$REPO/build/fx-osier-share}"
[ -x "$OSIER" ] || fail "no oracle binary at $OSIER (make test-osier-share builds it)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/osiershare.XXXXXX")" || fail mktemp
if [ "${OSIER_KEEP:-0}" = "1" ]; then
    trap 'echo "test_osier_share: scratch kept at $WORK"' EXIT
else
    trap 'rm -rf "$WORK"' EXIT
fi
STORE="$WORK/store"
mkdir -p "$STORE" || fail "cannot create the store"

# the fxstore reader capability (needs a dir, hence here): on an EMPTY store
# a KNOWN relation fails with "no published snapshot" while an unknown one
# fails with "unknown relation 'src_of'" — the stale-binary case is a SKIP
# with the reason, not a mystery failure inside the oracle later.
mkdir -p "$WORK/capprobe"
if "$FXSTORE" facts src_of --store "$WORK/capprobe" 2>&1 | grep -q "unknown relation 'src_of'"; then
    skip "fxstore at $FXSTORE predates 'facts src_of' — rebuild the sibling checkout (zig build)"
fi

# ── the synthetic components ────────────────────────────────────────────
# Fixed-content sources (sizes are MEASURED below, never hardcoded — the
# assertions compare the oracle's numbers against these same measurements).
SRC="$WORK/src"
mkdir -p "$SRC/osier-svc" "$SRC/c-svc" "$SRC/deadwood" "$SRC/tool"
{
    echo "-- the osier main module of the discrimination fixture"
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
    echo "/* util */"
    i=0; while [ $i -lt 2 ]; do echo "int u_line_$i = $i;"; i=$((i+1)); done
} > "$SRC/c-svc/util.c"
{
    echo "-- dead osier code: built into the closure, run by nobody"
    i=0; while [ $i -lt 11 ]; do echo "dead_line_$i = $i -- osier source"; i=$((i+1)); done
} > "$SRC/deadwood/Dead.elm"
{
    echo "/* the four tool packages share this tree; a .c file keeps the"
    echo "   closure share non-degenerate (not every closure byte is elm) */"
    i=0; while [ $i -lt 5 ]; do echo "int tool_line_$i = $i;"; i=$((i+1)); done
} > "$SRC/tool/tool.c"

sz() { wc -c < "$1" | tr -d ' '; }
OSIER_BYTES=$(( $(sz "$SRC/osier-svc/Main.elm") + $(sz "$SRC/osier-svc/Util.elm") ))
C_BYTES=$(( $(sz "$SRC/c-svc/main.c") + $(sz "$SRC/c-svc/util.c") ))
DEAD_BYTES=$(sz "$SRC/deadwood/Dead.elm")
TOOL_BYTES=$(sz "$SRC/tool/tool.c")
[ "$OSIER_BYTES" -gt 0 ] && [ "$C_BYTES" -gt 0 ] && [ "$DEAD_BYTES" -gt 0 ] || fail "fixture bytes degenerate"

# ── the package set (absolute src paths; empty recipes — nothing runs) ──
PSN=0
ps_pkg() { # ps_pkg NAME SRCDIR — one package entry (comma only after the first)
    if [ "$PSN" -eq 0 ]; then
        echo "  { name = \"$1\", version = \"0\""
    else
        echo "  , { name = \"$1\", version = \"0\""
    fi
    PSN=$((PSN + 1))
    # < Path = ... > (the m3 shorthand), NOT Src.Path "...": this dhall-c's
    # normalize does not reduce union projections to literals, and the
    # oracle's JSON walk (term_to_json) refuses the un-reduced form — the
    # shorthand is what the real m3 package-set uses for src.
    cat <<EOF
    , src = < Path = "$2" >
    , deps = [] : List Text
    , excludes = [] : List Text
    , build = { target = "$1", recipe = [] : List Action } }
EOF
}
{
    cat <<'EOF'
-- the discrimination fixture's own package set: every src is a synthetic
-- tree in this scratch dir; recipes are empty because nothing ever builds
-- (toolchain-free provisioning pre-creates the store dirs).
let Action = < Shell : Text | Copy : { from : Text, to : Text } | Mkdir : Text
             | Rm : Text | Touch : Text | Move : { from : Text, to : Text }
             | Symlink : { from : Text, to : Text } | Chmod : { path : Text, mode : Text }
             | Echo : Text | Env : { key : Text, value : Text } | Run : { argv : List Text } >
let Src = < Path : Text | Fetch : { url : Text, hash : Text } >
EOF
    cat <<EOF
let Package = { name : Text, version : Text, src : Src, deps : List Text,
                excludes : List Text, build : { target : Text, recipe : List Action } }
in  { packages = [
EOF
    # fx-activate REQUIRES these four in every closure (activate.zig:1059)
    ps_pkg dhake        "$SRC/tool"
    ps_pkg fx-init      "$SRC/tool"
    ps_pkg fxctl        "$SRC/tool"
    ps_pkg fx-activate  "$SRC/tool"
    ps_pkg osier-svc    "$SRC/osier-svc"
    ps_pkg c-svc        "$SRC/c-svc"
    ps_pkg deadwood     "$SRC/deadwood"
    ps_pkg ambig        "$SRC/ambig"
    echo "  ] }"
} > "$WORK/package-set.dhall" || fail "cannot write the package set"
PKGSET="$WORK/package-set.dhall"

# ── provision the store, toolchain-free (qemu-agent-observe.sh shape) ───
PATHS=$(LD_LIBRARY_PATH="$DL" "$ZB/activate_paths" \
    --store "$STORE" --package-set "$PKGSET" \
    dhake fx-init fxctl fx-activate osier-svc c-svc deadwood) || fail "activate_paths failed: $PATHS"
[ -n "$PATHS" ] || fail "activate_paths printed no closure"
echo "$PATHS" | while IFS= read -r pd; do
    mkdir -p "$STORE/$pd" || exit 1
    : > "$STORE/$pd/.provisioned-by-test-osier-share"
done || fail "cannot create the closure dirs"
NPROV=$(echo "$PATHS" | grep -c . )
[ "$NPROV" -eq 7 ] || fail "expected 7 closure dirs, got $NPROV"

# ── the configs (the Service/User records fx-activate parses) ───────────
cfg_write() { # cfg_write OUT PKGLIST SVCLIST
    cat > "$1" <<EOF
let Probe = < Tcp : Natural | Unix : Text | File : Text >
let Service = { name : Text, argv : List Text, pkg : Optional Text, on : Text,
                restart : Optional Text, backoffMs : Optional Natural,
                probe : Optional Probe,
                env : Optional (List { key : Text, value : Text }),
                console : Optional Text }
let User = { name : Text, uid : Natural, groups : List Text }
in  { hostname = "osierbox"
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
svc_sh() { # a NON-pkg'd service: svc_bin records argv[0] VERBATIM
    echo '{ name = "shsvc", argv = [ "/bin/sh", "-c", "true" ], pkg = None Text, on = "all", restart = Some "always", backoffMs = Some 500, probe = None Probe, env = None (List { key : Text, value : Text }), console = None Text }'
}
svc_osier() {
    echo '{ name = "osierd", argv = [ "osier-svc" ], pkg = Some "osier-svc", on = "all", restart = Some "always", backoffMs = Some 500, probe = None Probe, env = None (List { key : Text, value : Text }), console = None Text }'
}
svc_c() {
    echo '{ name = "cd", argv = [ "c-svc" ], pkg = Some "c-svc", on = "all", restart = Some "always", backoffMs = Some 500, probe = None Probe, env = None (List { key : Text, value : Text }), console = None Text }'
}

# E: nothing store-run (only the verbatim /bin/sh) -> the run share is 0/0
cfg_write "$WORK/E.dhall" "$TOOLS" "$(svc_sh)"
# A: + the Osier component, RUN  (assertion 1 moves this)
cfg_write "$WORK/A.dhall" "$TOOLS, \"osier-svc\"" "$(svc_sh), $(svc_osier)"
# C: A + deadwood in the closure, run by NOBODY  (assertion 2)
cfg_write "$WORK/C.dhall" "$TOOLS, \"osier-svc\", \"deadwood\"" "$(svc_sh), $(svc_osier)"
# D: A + the C component, RUN  (assertion 3)
cfg_write "$WORK/D.dhall" "$TOOLS, \"osier-svc\", \"c-svc\"" "$(svc_sh), $(svc_osier), $(svc_c)"

activate() { # activate CFG -> version N on stdout
    _act_out=$(LD_LIBRARY_PATH="$DL" "$ZB/fx-activate" --store "$STORE" \
        --package-set "$PKGSET" --config "$1" 2>&1) || fail "fx-activate $1 failed: $_act_out"
    echo "$_act_out" | sed -n 's/.*as version \([0-9][0-9]*\).*/\1/p' | head -1
}

run_oracle() { # run_oracle [extra args...] -> oracle stdout
    FXSTORE_BIN="$FXSTORE" "$OSIER" --store "$STORE" --package-set "$PKGSET" "$@"
}
nattr() { # nattr FILE -> the nonstore_run_unattributed count (mid-line)
    grep -o 'nonstore_run_unattributed [0-9][0-9]*' "$1" | head -1 | awk '{print $2}'
}
field() { # field FILE KEY -> the value after the key (first match)
    sed -n "s/^$2 //p" "$1" | head -1
}

# ── v_E: the baseline (fail-before arm of assertion 1) ──────────────────
V_E=$(activate "$WORK/E.dhall"); [ -n "$V_E" ] || fail "no version from E activation"
run_oracle > "$WORK/out.E" || fail "oracle failed on E: $(cat "$WORK/out.E" 2>/dev/null)"
E_FRAC=$(field "$WORK/out.E" run_set_share_fraction)
E_TOT=$(field "$WORK/out.E" run_set_total_bytes)
E_OS=$(field "$WORK/out.E" run_set_osier_bytes)
[ "$E_TOT" = "0" ] && [ "$E_OS" = "0" ] && [ "$E_FRAC" = "0.000000" ] \
    || fail "E baseline wrong: total=$E_TOT osier=$E_OS frac=$E_FRAC (want 0/0 -> 0.000000)"
grep -qx "service shsvc /bin/sh NONSTORE-UNATTRIBUTED" "$WORK/out.E" \
    || fail "E does not report the verbatim /bin/sh service as NONSTORE-UNATTRIBUTED (an absolute argv[0] nothing attributes must be VISIBLE, flagged)"
[ "$(nattr "$WORK/out.E")" = 1 ] \
    || fail "E: nonstore_run_unattributed is not 1"
grep -q '^osier_extensions \.elm$' "$WORK/out.E" \
    || fail "the oracle does not print its frozen extension set"

# ── v_A: the Osier component RUNS (pass-after arm of assertion 1) ───────
V_A=$(activate "$WORK/A.dhall"); [ -n "$V_A" ] || fail "no version from A activation"
# materialize ONE clean-source artifact (origin "store"); c-svc stays on the
# host fallback so BOTH origins are exercised by D
OSIER_SRC_HASH=$(FXSTORE_BIN="$FXSTORE" "$FXSTORE" facts srcstore --as-of "$V_A" --store "$STORE" \
    | awk -F'\t' '$2 == "osier-svc" { print $1; exit }')
[ -n "$OSIER_SRC_HASH" ] || fail "no srcstore row for osier-svc as-of $V_A"
cp -r "$SRC/osier-svc" "$STORE/$OSIER_SRC_HASH-osier-svc-src" || fail "cannot materialize the -src artifact"
run_oracle > "$WORK/out.A" || fail "oracle failed on A"
A_FRAC=$(field "$WORK/out.A" run_set_share_fraction)
A_TOT=$(field "$WORK/out.A" run_set_total_bytes)
A_OS=$(field "$WORK/out.A" run_set_osier_bytes)
[ "$A_OS" = "$OSIER_BYTES" ] || fail "A osier bytes: got $A_OS want $OSIER_BYTES (measured fixture bytes)"
[ "$A_TOT" = "$OSIER_BYTES" ] || fail "A total bytes: got $A_TOT want $OSIER_BYTES (the run set is exactly the osier tree)"
[ "$A_FRAC" = "1.000000" ] || fail "A fraction: got $A_FRAC want 1.000000"
grep -q "^component osier-svc $OSIER_SRC_HASH store " "$WORK/out.A" \
    || fail "A does not report osier-svc with origin store"
# ASSERTION 1: the number MOVES 0 -> non-zero
[ "$A_FRAC" != "$E_FRAC" ] || fail "ASSERTION 1 FAILED: adding a RUN Osier component did not move the share ($E_FRAC -> $A_FRAC)"
echo "test_osier_share: A1 MOVES: run share $E_FRAC -> $A_FRAC (osier $A_OS/$A_TOT bytes)"

# ── v_C: deadwood built, run by nobody (assertion 2) ────────────────────
V_C=$(activate "$WORK/C.dhall"); [ -n "$V_C" ] || fail "no version from C activation"
run_oracle > "$WORK/out.C" || fail "oracle failed on C"
C_FRAC=$(field "$WORK/out.C" run_set_share_fraction)
C_TOT=$(field "$WORK/out.C" run_set_total_bytes)
C_OS=$(field "$WORK/out.C" run_set_osier_bytes)
C_CL=$(field "$WORK/out.C" closure_share_fraction)
A_CL=$(field "$WORK/out.A" closure_share_fraction)
A_CLOS_O=$(field "$WORK/out.A" closure_osier_bytes)
C_CLOS_O=$(field "$WORK/out.C" closure_osier_bytes)
# ASSERTION 2a: the RUN share is EXACTLY invariant (bytes AND fraction)
[ "$C_FRAC" = "$A_FRAC" ] && [ "$C_TOT" = "$A_TOT" ] && [ "$C_OS" = "$A_OS" ] \
    || fail "ASSERTION 2a FAILED: a built-but-not-run component moved the RUN share ($A_FRAC/$A_TOT/$A_OS -> $C_FRAC/$C_TOT/$C_OS) — the oracle is counting the closure"
# ASSERTION 2b: the CLOSURE share DID move (the numbers are different
# measurements and the comparison number is not inert either)
[ "$C_CLOS_O" = "$((A_CLOS_O + DEAD_BYTES))" ] \
    || fail "ASSERTION 2b FAILED: closure osier bytes $A_CLOS_O -> $C_CLOS_O, expected +$DEAD_BYTES"
[ "$C_CL" != "$A_CL" ] || fail "ASSERTION 2b FAILED: closure share inert ($A_CL)"
echo "test_osier_share: A2 DEAD-CODE: run share invariant $A_FRAC; closure moved $A_CL -> $C_CL"

# ── v_D: a RUN component whose source is NOT Osier (assertion 3) ────────
V_D=$(activate "$WORK/D.dhall"); [ -n "$V_D" ] || fail "no version from D activation"
run_oracle > "$WORK/out.D" || fail "oracle failed on D"
D_FRAC=$(field "$WORK/out.D" run_set_share_fraction)
D_OS=$(field "$WORK/out.D" run_set_osier_bytes)
D_TOT=$(field "$WORK/out.D" run_set_total_bytes)
# ASSERTION 3: does not RAISE — numerator invariant, denominator grows
[ "$D_OS" = "$A_OS" ] || fail "ASSERTION 3 FAILED: osier numerator moved $A_OS -> $D_OS"
[ "$D_TOT" = "$((A_TOT + C_BYTES))" ] \
    || fail "ASSERTION 3: denominator $D_TOT, expected $((A_TOT + C_BYTES))"
awk -v a="$A_FRAC" -v d="$D_FRAC" 'BEGIN { exit !(d < a) }' \
    || fail "ASSERTION 3 FAILED: a run non-Osier component RAISED the share ($A_FRAC -> $D_FRAC)"
grep -q "^component c-svc [0-9a-f]\\{64\\} host-verified " "$WORK/out.D" \
    || fail "D does not report c-svc with origin host-verified (the C clean-tree hash did not verify)"
grep -q "^component osier-svc $OSIER_SRC_HASH store " "$WORK/out.D" \
    || fail "D does not report osier-svc with origin store"
echo "test_osier-share: A3 NON-OSIER RUN: numerator invariant $D_OS bytes, share $A_FRAC -> $D_FRAC (strictly lower)"

# ── --as-of binds at the CLI level too ──────────────────────────────────
run_oracle --as-of "$V_A" > "$WORK/out.A2" || fail "oracle failed on --as-of $V_A"
cmp -s "$WORK/out.A" "$WORK/out.A2" \
    || fail "--as-of $V_A does not reproduce v_A's report (snapshot binding is broken)"

# ── the PRE-FIX ORACLE (pinned revision, never HEAD) ────────────────────
# The asymmetry arms below (A4/A5/A6 and the corrupted-artifact seat) each
# assert that the COMMITTED oracle — the one this round fixes — produces the
# wrong thing on the very same store.  The pin is a FIXED revision
# (e3eb984, the oracle commit), guarded by cat-file: a shallow clone says
# SKIP out loud rather than silently dropping the fail-before arms.  And the
# control's domain is asserted: if the pinned source EQUALS the working one
# the arm would compare the code to itself and prove nothing.
OSIER_PRE=""
PRE_ORACLE_REV="e3eb984"
if git -C "$REPO" cat-file -e "$PRE_ORACLE_REV^{commit}" 2>/dev/null; then
    OSIER_PRE="$WORK/fx-osier-share-prefix"
    git -C "$REPO" show "$PRE_ORACLE_REV:tools/fx-osier-share.c" > "$WORK/osier-prefix.c" 2>/dev/null \
        || { echo "test_osier_share: SKIP (cannot extract $PRE_ORACLE_REV:tools/fx-osier-share.c)"; OSIER_PRE=""; }
    if [ -n "$OSIER_PRE" ] && cmp -s "$WORK/osier-prefix.c" "$REPO/tools/fx-osier-share.c"; then
        echo "test_osier_share: SKIP ($PRE_ORACLE_REV's oracle source is IDENTICAL to the working tree — the asymmetry arms would compare the code to itself)"
        OSIER_PRE=""
    fi
    if [ -n "$OSIER_PRE" ]; then
        cc -std=c11 -O2 -Wall -Wextra \
           -I"$REPO/src" -I"$REPO/src/vendor/dhall-c" -I"$REPO/src/vendor/yyjson" \
           -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE \
           -o "$OSIER_PRE" "$WORK/osier-prefix.c" \
           "$REPO"/src/vendor/dhall-c/*.c "$REPO/src/vendor/yyjson/yyjson.c" \
           || fail "cannot build the $PRE_ORACLE_REV oracle"
    fi
else
    echo "test_osier_share: SKIP (pre-fix revision $PRE_ORACLE_REV unavailable — the A4/A5/A6 fail-before arms cannot run)"
fi
run_pre() { # the PRE-FIX oracle on the same store
    FXSTORE_BIN="$FXSTORE" "$OSIER_PRE" --store "$STORE" --package-set "$PKGSET" "$@"
}

# ── A5: an ABSOLUTE argv[0] on an INSTALL TARGET is a RUN component ─────
# The denominator-shrink hole: a config installs /bin/<tool> from a package
# (the four fixed /bin links — init, fxctl, dhake, fx-activate — are written
# on EVERY activation, no service needed) and runs it with pkg=None.  The
# svc_bin row is the absolute path; the oracle that treats every absolute
# argv[0] as non-store DROPPED the package's bytes from numerator AND
# denominator — the run share was inflatable to 1.0 by config alone.  The
# fixed oracle resolves the absolute path through the activation's own
# install facts.
svc_dhake() { # a pkg=None service running an INSTALL TARGET absolutely
    echo '{ name = "dhakesvc", argv = [ "/bin/dhake", "--probe" ], pkg = None Text, on = "all", restart = Some "always", backoffMs = Some 500, probe = None Probe, env = None (List { key : Text, value : Text }), console = None Text }'
}
cfg_write "$WORK/DH.dhall" "$TOOLS, \"osier-svc\"" "$(svc_sh), $(svc_osier), $(svc_dhake)"
V_DH=$(activate "$WORK/DH.dhall"); [ -n "$V_DH" ] || fail "no version from DH activation"
run_oracle > "$WORK/out.DH" || fail "oracle failed on DH: $(head -2 "$WORK/out.DH" 2>/dev/null)"
DH_FRAC=$(field "$WORK/out.DH" run_set_share_fraction)
DH_OS=$(field "$WORK/out.DH" run_set_osier_bytes)
DH_TOT=$(field "$WORK/out.DH" run_set_total_bytes)
grep -qx "service dhakesvc /bin/dhake dhake" "$WORK/out.DH" \
    || fail "A5: the absolute /bin/dhake service is not attributed to the dhake package: $(grep '^service ' "$WORK/out.DH")"
grep -qx "service shsvc /bin/sh NONSTORE-UNATTRIBUTED" "$WORK/out.DH" \
    || fail "A5: the truly-unattributable /bin/sh row is not flagged NONSTORE-UNATTRIBUTED"
[ "$(nattr "$WORK/out.DH")" = 1 ] \
    || fail "A5: nonstore_run_unattributed is not 1 (the unattributable row must be counted, not just printed)"
[ "$DH_OS" = "$A_OS" ] || fail "A5: osier numerator moved $A_OS -> $DH_OS (dhake is not .elm)"
[ "$DH_TOT" = "$((A_TOT + TOOL_BYTES))" ] \
    || fail "A5: denominator $DH_TOT, expected A_TOT+TOOL_BYTES=$((A_TOT + TOOL_BYTES)) — the installed tool's bytes left the run set"
awk -v a="$A_FRAC" -v d="$DH_FRAC" 'BEGIN { exit !(d < a) }' \
    || fail "A5: the pkg=None install-target run RAISED the share ($A_FRAC -> $DH_FRAC)"
# ASYMMETRY: the PRE-FIX oracle dropped exactly these bytes.
if [ -n "$OSIER_PRE" ]; then
run_pre > "$WORK/out.DHpre" || fail "pre-fix oracle failed on DH"
PRE_TOT=$(field "$WORK/out.DHpre" run_set_total_bytes)
grep -qx "service dhakesvc /bin/dhake NONSTORE" "$WORK/out.DHpre" \
    || fail "A5 pre-fix asymmetry: the committed oracle did not mark /bin/dhake NONSTORE — the arm is vacuous"
[ "$PRE_TOT" = "$A_TOT" ] \
    || fail "A5 pre-fix asymmetry: the committed oracle's denominator is $PRE_TOT, expected the SHRUNK $A_TOT (the hole)"
echo "test_osier_share: A5 INSTALL-TARGET RUN: denominator $A_TOT(pre-fix, bytes silently dropped) -> $DH_TOT(fixed); share $A_FRAC -> $DH_FRAC"
else
echo "test_osier_share: A5: pre-fix arm skipped"
fi

# ── A6: the CLOSURE is the ACTIVE closure, not store history ────────────
# provides is cleared per activation; srcstore rows persist until the NAME
# is unreachable.  v_DH's provides is exactly TOOLS+osier-svc (deadwood and
# c-svc are history), while its srcstore still holds their rows — the
# committed (srcstore-driven) oracle kept counting them.
run_oracle --as-of "$V_DH" > "$WORK/out.A6" || fail "oracle failed on --as-of $V_DH"
A6_CLOS_O=$(field "$WORK/out.A6" closure_osier_bytes)
[ "$A6_CLOS_O" = "$A_CLOS_O" ] \
    || fail "ASSERTION A6 FAILED: closure osier bytes as-of the deadwood-free generation is $A6_CLOS_O, expected $A_CLOS_O (a dropped package is still being counted — the closure is store history, not the generation)"
grep -q "^component deadwood " "$WORK/out.A6" \
    && fail "ASSERTION A6 FAILED: deadwood is a closure component of a generation whose config does not include it"
grep -q "^closure_components_resolved 5 of 5$" "$WORK/out.A6" \
    || fail "A6: closure is not exactly the 5 provided packages: $(grep '^closure_components_resolved' "$WORK/out.A6")"
if [ -n "$OSIER_PRE" ]; then
run_pre --as-of "$V_DH" > "$WORK/out.A6pre" || fail "pre-fix oracle failed on --as-of $V_DH"
PRE_CLOS_O=$(field "$WORK/out.A6pre" closure_osier_bytes)
[ "$PRE_CLOS_O" = "$((A_CLOS_O + DEAD_BYTES))" ] \
    || fail "A6 pre-fix asymmetry: the committed oracle's closure osier bytes is $PRE_CLOS_O, expected A+DEAD=$((A_CLOS_O + DEAD_BYTES)) (deadwood still counted — the arm is vacuous)"
echo "test_osier_share: A6 ACTIVE CLOSURE: closure osier bytes $A_CLOS_O(fixed) vs $PRE_CLOS_O(pre-fix: deadwood history counted)"
else
echo "test_osier_share: A6: pre-fix arm skipped"
fi

# ── A4: srcstore ambiguity on rebuild — the src_of fact ANSWERS, and the
#    refusal survives only where the store genuinely cannot ───────────────
# A package whose source changed and was re-activated has TWO live srcstore
# rows for one name in the CURRENT snapshot (srcstore is append-only; rows
# are reaped only when the NAME becomes unreachable).  BOTH behaviours are
# pinned, because they are different claims about the SAME shape of store:
#   A4-resolve  with the NEW writer (working fx-init), src_of names the
#               exact src the CURRENT generation was folded from: the
#               oracle RESOLVES — to the v2 hash, NOT the v1 one — and says
#               so (attribution src_of); the older snapshot of the same
#               store resolves its OWN v1 hash (version-bound, no
#               retroactive claim).
#   A4-refuse   with the OLD writer (PINNED fx-init 2feedf6, whose
#               activate.zig predates src_of — cmp-guarded above), the
#               activations committed no src_of row: with both -src
#               artifacts materialized and verifying, NO independent check
#               can attribute the generation's source to one of them — the
#               oracle must REFUSE rather than print a number read through
#               an arbitrary first-wins pick.
mkdir -p "$SRC/ambig"
{ echo "-- the ambiguity fixture's osier module, revision 1"; } > "$SRC/ambig/A.elm"
cfg_write "$WORK/AMB.dhall" "$TOOLS, \"ambig\"" "$(svc_sh), { name = \"ambigd\", argv = [ \"ambig\" ], pkg = Some \"ambig\", on = \"all\", restart = Some \"always\", backoffMs = Some 500, probe = None Probe, env = None (List { key : Text, value : Text }), console = None Text }"
provision_ambig() { # pre-create ambig's closure dir for the CURRENT source
    _p=$(LD_LIBRARY_PATH="$DL" "$ZB/activate_paths" --store "$STORE" \
        --package-set "$PKGSET" ambig) || fail "activate_paths (ambig) failed: $_p"
    for _pd in $_p; do mkdir -p "$STORE/$_pd" || fail "cannot create $_pd"; done
}
provision_ambig
V_AMB1=$(activate "$WORK/AMB.dhall"); [ -n "$V_AMB1" ] || fail "no version from AMB activation 1"
AMB_H1=$(FXSTORE_BIN="$FXSTORE" "$FXSTORE" facts srcstore --as-of "$V_AMB1" --store "$STORE" \
    | awk -F'\t' '$2 == "ambig" { print $1; exit }')
[ -n "$AMB_H1" ] || fail "no srcstore row for ambig as-of $V_AMB1"
cp -r "$SRC/ambig" "$WORK/ambig-v1" || fail "cannot save the v1 tree"
echo "-- mutation: revision 2 (a different source, same package name)" >> "$SRC/ambig/A.elm"
provision_ambig
V_AMB2=$(activate "$WORK/AMB.dhall"); [ -n "$V_AMB2" ] || fail "no version from AMB activation 2"
AMB_H2=$(FXSTORE_BIN="$FXSTORE" "$FXSTORE" facts srcstore --as-of "$V_AMB2" --store "$STORE" \
    | awk -F'\t' '$2 == "ambig" && $1 != "'"$AMB_H1"'" { print $1; exit }')
NAMB_ROWS=$(FXSTORE_BIN="$FXSTORE" "$FXSTORE" facts srcstore --as-of "$V_AMB2" --store "$STORE" \
    | awk -F'\t' '$2 == "ambig"' | wc -l | tr -d ' ')
[ "$NAMB_ROWS" = 2 ] && [ -n "$AMB_H2" ] \
    || fail "A4 precondition: expected 2 live srcstore rows for ambig as-of $V_AMB2, saw $NAMB_ROWS (the ambiguity mechanism did not reproduce — check the review's Blocker 1 trace)"
cp -r "$WORK/ambig-v1" "$STORE/$AMB_H1-ambig-src" || fail "cannot materialize the v1 artifact"
cp -r "$SRC/ambig" "$STORE/$AMB_H2-ambig-src" || fail "cannot materialize the v2 artifact"
# premise: the NEW writer is really driving — ambig HAS a src_of row as-of
# V_AMB2 (a stale staged fx-activate would leave this empty and the resolve
# arm below would be testing the refusal against the wrong writer)
AMB_DIR=$(FXSTORE_BIN="$FXSTORE" "$FXSTORE" facts provides --as-of "$V_AMB2" --store "$STORE" \
    | awk -F'\t' '$1 == "ambig" { print $2; exit }')
AMB_DERIV=${AMB_DIR%%-*}
NAMB_SRCOF=$(FXSTORE_BIN="$FXSTORE" "$FXSTORE" facts src_of --as-of "$V_AMB2" --store "$STORE" \
    | awk -F'\t' -v d="$AMB_DERIV" '$1 == d && $3 == "ambig"' | wc -l | tr -d ' ')
[ "$NAMB_SRCOF" = 1 ] \
    || fail "A4 premise: ambig has $NAMB_SRCOF src_of rows keyed by its provides hash as-of $V_AMB2 (want 1 — is the staged fx-activate the src_of writer?)"

# A4-resolve: the oracle ANSWERS, through the store's own attribution —
# the v2 hash for the CURRENT generation, attribution src_of, and the
# measured v2 bytes (a first-wins pick of the WRONG row would print the v1
# bytes and this fails).
AMB_V1_BYTES=$(sz "$WORK/ambig-v1/A.elm")
AMB_V2_BYTES=$(sz "$SRC/ambig/A.elm")
[ "$AMB_V1_BYTES" != "$AMB_V2_BYTES" ] || fail "A4 fixture degenerate: v1 and v2 elm bytes are equal"
run_oracle > "$WORK/out.AMB" 2>"$WORK/err.AMB" || fail "A4-resolve: the oracle REFUSED a store src_of can answer: $(cat "$WORK/err.AMB")"
grep -q "^component ambig $AMB_H2 store $AMB_V2_BYTES $AMB_V2_BYTES 1 1 run src_of$" "$WORK/out.AMB" \
    || fail "A4-resolve: ambig is not resolved to the v2 hash $AMB_H2 with attribution src_of: $(grep '^component ambig' "$WORK/out.AMB")"
grep -q "^component ambig $AMB_H1 " "$WORK/out.AMB" \
    && fail "A4-resolve: ambig resolved to the WRONG (v1) hash $AMB_H1"
[ "$(field "$WORK/out.AMB" run_set_osier_bytes)" = "$AMB_V2_BYTES" ] \
    || fail "A4-resolve: run_set_osier_bytes is not the measured v2 bytes"
# version-bound: the SAME store's older snapshot resolves its OWN v1 hash —
# no retroactive claim
run_oracle --as-of "$V_AMB1" > "$WORK/out.AMBv1" 2>"$WORK/err.AMBv1" || fail "A4-resolve: --as-of $V_AMB1 refused: $(cat "$WORK/err.AMBv1")"
grep -q "^component ambig $AMB_H1 store $AMB_V1_BYTES $AMB_V1_BYTES 1 1 run src_of$" "$WORK/out.AMBv1" \
    || fail "A4-resolve: as-of $V_AMB1 ambig must resolve to the v1 hash $AMB_H1 (version-bound): $(grep '^component ambig' "$WORK/out.AMBv1")"
grep -q "^attribution src_of 5 srcstore-narrowed 0 (of 5 resolved)$" "$WORK/out.AMB" \
    || fail "A4-resolve: the attribution summary is not 'src_of 5, narrowed 0': $(grep '^attribution' "$WORK/out.AMB")"
echo "test_osier_share: A4 RESOLVES: ambig -> $AMB_H2 (not $AMB_H1) via src_of; v$V_AMB1 -> $AMB_H1; attribution printed"

# A4-refuse: the OLD writer's store — no src_of row for the generation, two
# verifying candidates, and the oracle must still REFUSE, naming both
if [ "$HAVE_OLD_WRITER" = 1 ]; then
STORE_OLD="$WORK/store-oldwriter"; mkdir -p "$STORE_OLD"
old_prov() { # pre-create the OLD store's closure dirs (pinned writer)
    _p=$(LD_LIBRARY_PATH="$DL" "$OLD_INIT_OUT/bin/activate_paths" --store "$STORE_OLD" \
        --package-set "$PKGSET" dhake fx-init fxctl fx-activate ambig) \
        || fail "old activate_paths failed: $_p"
    for _pd in $_p; do mkdir -p "$STORE_OLD/$_pd" || fail "cannot create $_pd (old store)"; done
}
old_act() { # old_act CFG -> version N on stdout
    _o=$(LD_LIBRARY_PATH="$DL" "$OLD_INIT_OUT/bin/fx-activate" --store "$STORE_OLD" \
        --package-set "$PKGSET" --config "$WORK/AMB.dhall" 2>&1) \
        || fail "OLD fx-activate failed: $_o"
    echo "$_o" | sed -n 's/.*as version \([0-9][0-9]*\).*/\1/p' | head -1
}
echo "-- old-writer fixture revision 3 (a fresh source state for the OLD store)" >> "$SRC/ambig/A.elm"
cp -r "$SRC/ambig" "$WORK/ambig-v3" || fail "cannot save the v3 tree"
old_prov
OV1=$(old_act); [ -n "$OV1" ] || fail "no version from the OLD activation 1"
OH1=$(FXSTORE_BIN="$FXSTORE" "$FXSTORE" facts srcstore --as-of "$OV1" --store "$STORE_OLD" \
    | awk -F'\t' '$2 == "ambig" { print $1; exit }')
[ -n "$OH1" ] || fail "no srcstore row for ambig as-of $OV1 (old store)"
echo "-- old-writer fixture revision 4 (the second live row)" >> "$SRC/ambig/A.elm"
old_prov
OV2=$(old_act); [ -n "$OV2" ] || fail "no version from the OLD activation 2"
OH2=$(FXSTORE_BIN="$FXSTORE" "$FXSTORE" facts srcstore --as-of "$OV2" --store "$STORE_OLD" \
    | awk -F'\t' '$2 == "ambig" && $1 != "'"$OH1"'" { print $1; exit }')
NOLD_ROWS=$(FXSTORE_BIN="$FXSTORE" "$FXSTORE" facts srcstore --as-of "$OV2" --store "$STORE_OLD" \
    | awk -F'\t' '$2 == "ambig"' | wc -l | tr -d ' ')
[ "$NOLD_ROWS" = 2 ] && [ -n "$OH2" ] \
    || fail "A4-refuse precondition: expected 2 live srcstore rows for ambig as-of $OV2 (old store), saw $NOLD_ROWS"
# the PREMISE of the refusal: the OLD writer committed NO src_of row — the
# store genuinely cannot attribute this generation's source
NOLD_SRCOF=$(FXSTORE_BIN="$FXSTORE" "$FXSTORE" facts src_of --as-of "$OV2" --store "$STORE_OLD" \
    | awk -F'\t' '$3 == "ambig"' | wc -l | tr -d ' ')
[ "$NOLD_SRCOF" = 0 ] \
    || fail "A4-refuse premise: the OLD writer committed $NOLD_SRCOF src_of rows (the pin is not the pre-src_of writer?)"
cp -r "$WORK/ambig-v3" "$STORE_OLD/$OH1-ambig-src" || fail "cannot materialize the old-store v3 artifact"
cp -r "$SRC/ambig" "$STORE_OLD/$OH2-ambig-src" || fail "cannot materialize the old-store v4 artifact"
if FXSTORE_BIN="$FXSTORE" "$OSIER" --store "$STORE_OLD" --package-set "$PKGSET" \
        > "$WORK/out.OLD" 2>"$WORK/err.OLD"; then
    fail "ASSERTION A4-refuse FAILED: the OLD writer's ambiguous store produced a NUMBER (exit 0) instead of refusing"
fi
grep -q 'FAIL' "$WORK/err.OLD" || fail "A4-refuse: no FAIL on stderr"
grep -q "ambig" "$WORK/err.OLD" || fail "A4-refuse: the refusal does not NAME the package"
grep -q "$OH1" "$WORK/err.OLD" || fail "A4-refuse: the refusal does not name candidate $OH1"
grep -q "$OH2" "$WORK/err.OLD" || fail "A4-refuse: the refusal does not name candidate $OH2"
grep -q "cannot attribute" "$WORK/err.OLD" || fail "A4-refuse: the refusal does not say the store cannot attribute one: $(cat "$WORK/err.OLD")"
grep -q "run_set_share_fraction" "$WORK/out.OLD" 2>/dev/null \
    && fail "A4-refuse: the refusal printed a share"
echo "test_osier_share: A4 REFUSES (old writer $OLD_INIT_REV, no src_of): names $OH1 and $OH2"
else
echo "test_osier_share: A4-refuse: old-writer arm skipped (pinned fx-init unavailable)"
fi
# ASYMMETRY: the committed oracle printed a number through an arbitrary pick
if [ -n "$OSIER_PRE" ]; then
run_pre > "$WORK/out.AMBpre" 2>"$WORK/err.AMBpre" \
    || fail "A4 pre-fix asymmetry: the committed oracle REFUSED the ambiguous store — expected a silent number (did it already die on ambiguity?)"
grep -q "^component ambig " "$WORK/out.AMBpre" \
    || fail "A4 pre-fix asymmetry: no ambig component row in the committed oracle's output"
grep -q "^run_set_share_fraction " "$WORK/out.AMBpre" \
    || fail "A4 pre-fix asymmetry: the committed oracle printed no share"
echo "test_osier_share: A4 asymmetry: fixed RESOLVES via src_of (and refuses only pre-fact stores); $PRE_ORACLE_REV printed a number (first-wins pick)"
else
echo "test_osier_share: A4: pre-fix arm skipped"
fi

# ── the refusal seat ────────────────────────────────────────────────────
# an unreadable store: a loud error, NEVER a 0%
mkdir -p "$WORK/empty-store"
if FXSTORE_BIN="$FXSTORE" "$OSIER" --store "$WORK/empty-store" > "$WORK/out.empty" 2>"$WORK/err.empty"; then
    fail "an empty store SUCCEEDED (exit 0) instead of refusing"
fi
grep -q 'FAIL' "$WORK/err.empty" || fail "empty store: no FAIL on stderr"
grep -q 'run_set_share_fraction 0' "$WORK/out.empty" 2>/dev/null \
    && fail "empty store printed a 0% instead of refusing"
# a nonexistent version
run_oracle --as-of 99999 > "$WORK/out.badv" 2>"$WORK/err.badv" \
    && fail "--as-of 99999 SUCCEEDED instead of refusing"
grep -q 'FAIL' "$WORK/err.badv" || fail "--as-of 99999: no FAIL on stderr"
# a RUN component whose only source is a MUTATED host tree: the clean hash
# no longer equals srcstore's version-bound hash -> refuse, never accept
rm -rf "$STORE/$OSIER_SRC_HASH-osier-svc-src"
echo "-- mutation after activation" >> "$SRC/osier-svc/Util.elm"
run_oracle --as-of "$V_D" > "$WORK/out.mut" 2>"$WORK/err.mut" \
    && fail "a mutated run-component tree was ACCEPTED (exit 0) instead of refused"
grep -q 'unverified tree refused' "$WORK/err.mut" \
    || fail "mutation refusal has the wrong reason: $(cat "$WORK/err.mut")"
grep -q 'run_set_share_fraction' "$WORK/out.mut" 2>/dev/null \
    && fail "the mutated-tree run printed a share instead of refusing"
# a CORRUPTED STORE ARTIFACT is refused too (the artifact origin was accepted
# UNVERIFIED: it existed -> walked with hash_out NULL -> tallied).  The tree
# is still mutated, so materializing the -src artifact from it yields a dir
# that does NOT hash back to the srcstore row — the fixed oracle refuses,
# the committed one tallied it silently.
cp -r "$SRC/osier-svc" "$STORE/$OSIER_SRC_HASH-osier-svc-src" || fail "cannot plant the corrupted artifact"
if run_oracle --as-of "$V_D" > "$WORK/out.art" 2>"$WORK/err.art"; then
    fail "ASSERTION (corrupted artifact) FAILED: a -src artifact that does not hash back to its srcstore row was ACCEPTED (exit 0)"
fi
grep -q 'FAIL' "$WORK/err.art" || fail "corrupted-artifact refusal: no FAIL on stderr"
grep -q 'unverified tree refused' "$WORK/err.art" \
    || fail "corrupted-artifact refusal has the wrong reason: $(cat "$WORK/err.art")"
if [ -n "$OSIER_PRE" ]; then
run_pre --as-of "$V_D" > "$WORK/out.artpre" 2>"$WORK/err.artpre" \
    || fail "corrupted-artifact pre-fix asymmetry: the committed oracle refused — expected the silent tally"
grep -q "^component osier-svc $OSIER_SRC_HASH store " "$WORK/out.artpre" \
    || fail "corrupted-artifact pre-fix asymmetry: the committed oracle did not tally the corrupted artifact as origin store: $(grep '^component osier-svc' "$WORK/out.artpre")"
echo "test_osier_share: corrupted artifact: fixed REFUSES; $PRE_ORACLE_REV tallied it silently (origin store, no hash check)"
fi

echo "test_osier_share: PASS — the oracle discriminates (moves on Osier-run," \
     "invariant on dead code, non-raising on non-Osier-run, attributes install" \
     "targets run absolutely, refuses srcstore ambiguity and unverified/corrupted" \
     "artifacts, and counts the ACTIVE closure, not store history)"
exit 0
