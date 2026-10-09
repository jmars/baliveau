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
# Env: FXSTORE_BIN (default ../fxstore/zig-out/bin/fxstore), FX_INIT_REPO,
#      OSIER_KEEP=1.
set -u

fail() { echo "test_osier_share: FAIL: $*" >&2; exit 1; }
skip() { echo "test_osier_share: SKIP ($*)"; exit 77; }

cd "$(dirname "$0")/.." || fail "cannot cd to repo root"
REPO="$PWD"
SIBS="$(cd "$REPO/.." && pwd)"

command -v cc >/dev/null 2>&1 || skip "cc not found"
command -v wc >/dev/null 2>&1 || skip "wc not found"

FXSTORE="${FXSTORE_BIN:-$SIBS/fxstore/zig-out/bin/fxstore}"
[ -x "$FXSTORE" ] || skip "fxstore binary missing at $FXSTORE (build the sibling)"
"$FXSTORE" --help 2>&1 | grep -q 'fxstore facts' || skip "fxstore at $FXSTORE predates 'facts' (rebuild the sibling)"

INIT="${FX_INIT_REPO:-$SIBS/fx-init}"
[ -d "$INIT" ] || skip "fx-init checkout not found at $INIT (set FX_INIT_REPO)"
DL="$SIBS/datalog-dafsa/zig-out/lib"
[ -f "$DL/libdatalog.so" ] || skip "libdatalog.so missing at $DL"

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
grep -qx "service shsvc /bin/sh NONSTORE" "$WORK/out.E" \
    || fail "E does not report the verbatim /bin/sh service as NONSTORE"
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

echo "test_osier_share: PASS — the oracle discriminates (moves on Osier-run," \
     "invariant on dead code, non-raising on non-Osier-run) and refuses loudly"
exit 0
