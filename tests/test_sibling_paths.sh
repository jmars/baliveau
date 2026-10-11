#!/bin/sh
# tests/test_sibling_paths.sh — the sibling-resolution gate.
#
# WHY.  This tree used to live inside the fx stack's workspace, beside
# fx-init / fxstore / datalog-dafsa.  It now lives at $HOME/futaie/baliveau,
# whose parent holds none of them, and every gate still resolved its siblings
# as "$(cd "$REPO/.." && pwd)" — so each one SKIPPED (exit 77) about a path
# that can never be right again, quietly enough to read as a pass.  This gate
# proves the one resolution policy is LIVE in every site:
#
#   SIBS="${FX_SIBLINGS:-$(cd "$REPO/.." && pwd)}"
#   [ -d "$SIBS/fx-init" ] || [ -n "${FX_SIBLINGS:-}" ] || SIBS="$HOME/fixpoint-linux"
#
# FX_SIBLINGS is an explicit override and WINS (even a bogus one — then the
# site skips loudly naming it, arm A2); else the historical neighbour $REPO/..
# is kept only if it actually holds the stack (fx-init present), which
# preserves the old behaviour for a checkout that still sits beside the stack;
# else the relocated default $HOME/fixpoint-linux.
#
# PIN.  The pre-fix scripts come from the commit below — the last commit before
# the sibling-path sweep.  The pin is cmp'd against the working tree, so a pin
# that happens to equal the working script FAILS as vacuous instead of proving
# nothing.
#
# TIMEOUT BUDGET (seconds per run; override with FX_SIBLING_GATE_*).  These are
# wall-clock bounds, not asserts: an arm that reaches its bound has shown
# exactly what the arm is for — that the run got PAST resolution.
#   HOST=900   the three host-side gates (the audit gate takes ~5m10s alone)
#   QEMU=30    each qemu gate — bounded so no guest is booted to completion;
#              a killed run's stop reason is reported, and is not a failure
#   STAGE=300  tools/stage-guest.sh
#
# SCOPE.  This gate changes nothing; it exercises the scripts as they are.  It
# writes one temporary mirror directory under the historical sibling root
# ($REPO/..) for the pinned pre-fix runs, and removes it on exit.  Every arm
# runs with the sibling family UNSET — FX_SIBLINGS / FXSTORE_BIN /
# FX_INIT_REPO / DATALOG_DIR / FXSTORE_REPO — except the arms that pin one of
# them deliberately (A2, A4).
#
# Env: FX_SIBLING_GATE_HOST / FX_SIBLING_GATE_QEMU / FX_SIBLING_GATE_STAGE
set -u

PIN_REV=0f2c902d422eaa9c5695acf8e59aa5d818981314

TIMEOUT_HOST="${FX_SIBLING_GATE_HOST:-900}"
TIMEOUT_QEMU="${FX_SIBLING_GATE_QEMU:-30}"
TIMEOUT_STAGE="${FX_SIBLING_GATE_STAGE:-300}"
TIMEOUT_PREFIX=120                       # pinned pre-fix runs skip at once

HOST_GATES="tests/test_osier_share.sh tests/test_fx_report.sh tests/test_fx_audit.sh"
QEMU_GATES="tests/qemu-agent.sh tests/qemu-agent-observe.sh tests/qemu-agent-b2.sh tests/qemu-agent-slot.sh tests/qemu-agent-slot-inguest.sh tests/qemu-luajit.sh"
TOOL_GATES="tools/stage-guest.sh"
ALL_SITES="$HOST_GATES $QEMU_GATES $TOOL_GATES"

cd "$(dirname "$0")/.." || { echo "test_sibling_paths: FAIL: cannot cd to repo root"; exit 1; }
REPO="$PWD"
OLD="$(cd "$REPO/.." && pwd)"           # the historical (now stale) sibling root
NEW="$HOME/fixpoint-linux"              # the relocated default

command -v timeout >/dev/null 2>&1 || { echo "test_sibling_paths: SKIP (timeout not found)"; exit 77; }

W="$(mktemp -d "${TMPDIR:-/tmp}/siblingpaths.XXXXXX")" || { echo "test_sibling_paths: FAIL: mktemp"; exit 1; }
MIRROR="$OLD/.sibling-path-sweep-$$"
cleanup() { rm -rf "$W" "$MIRROR"; }
trap cleanup EXIT
mkdir -p "$W/pin" "$W/tmp" "$MIRROR/tests" || exit 1

NARM=0
FAILED=0
NOTES="$W/notes"
: >"$NOTES"

arm()   { NARM=$((NARM + 1)); printf 'PASS  %-8s %-34s %s\n' "$1" "$2" "$3"; }
bad()   { NARM=$((NARM + 1)); FAILED=$((FAILED + 1)); printf 'FAIL  %-8s %-34s %s\n' "$1" "$2" "$3"; }
note()  { printf '%s\n' "$*" | tee -a "$NOTES" >&2; }

# ── helpers ───────────────────────────────────────────────────────────────
# NOOVERRIDE <cmd...> — run with the whole sibling family unset, so the arm
# exercises the DEFAULT resolution and nothing else.
NOOVERRIDE() { env -u FX_SIBLINGS -u FXSTORE_BIN -u FX_INIT_REPO -u DATALOG_DIR -u FXSTORE_REPO "$@"; }

# stale_hit <outfile> — the first stale sibling path named in <outfile>, if any
stale_hit() {
    for s in "$OLD/fx-init" "$OLD/fxstore" "$OLD/datalog-dafsa"; do
        if grep -q -F -- "$s" "$1"; then printf '%s\n' "$s"; return 0; fi
    done
    return 1
}

# where <outfile> <rc> <bound> — one line saying where a run stopped
where() {
    if [ "$2" = 124 ] || [ "$2" = 137 ]; then printf 'reached the %ss bound (killed)' "$3"; return; fi
    if [ "$2" = 77 ]; then printf 'SKIP — %s' "$(grep -m1 'SKIP (' "$1" | sed 's/^[^:]*: SKIP //' | cut -c1-70)"; return; fi
    if [ "$2" = 0 ]; then printf 'ran to completion (exit 0)'; return; fi
    printf 'verdict exit=%s — %s' "$2" "$(grep -m1 -E 'FAIL' "$1" | cut -c1-90)"
}

echo "test_sibling_paths: repo                            = $REPO"
echo "test_sibling_paths: historical sibling root (stale) = $OLD"
echo "test_sibling_paths: relocated default               = $NEW"
echo "test_sibling_paths: pre-fix pin                     = $PIN_REV"
echo "test_sibling_paths: budgets host=${TIMEOUT_HOST}s qemu=${TIMEOUT_QEMU}s stage=${TIMEOUT_STAGE}s"
echo

# ═══ A0 · the policy block is the SAME BYTES in every site ════════════════
# Uniformity is the point of the unit: a divergent copy is how this class of
# defect returns.  Asserted as exact lines, PLUS: no site may still carry an
# unguarded $REPO/.. sibling spelling.
cat >"$W/block" <<'BLOCK'
# Sibling root: an explicit FX_SIBLINGS wins; else the historical neighbour
# $REPO/.. only if it actually holds the stack (fx-init present); else the
# relocated default $HOME/fixpoint-linux.
SIBS="${FX_SIBLINGS:-$(cd "$REPO/.." && pwd)}"
[ -d "$SIBS/fx-init" ] || [ -n "${FX_SIBLINGS:-}" ] || SIBS="$HOME/fixpoint-linux"
BLOCK
A0=""
for f in $ALL_SITES; do
    while IFS= read -r line; do
        grep -q -F -x -- "$line" "$f" || A0="missing policy line in $f: $line"
        [ -z "$A0" ] || break
    done <"$W/block"
    [ -z "$A0" ] || break
done
if [ -n "$A0" ]; then
    bad A0 static "policy block in every site" "$A0"
else
    arm A0 static "$(printf '%s sites' "$(printf '%s\n' $ALL_SITES | wc -l)")" "byte-identical policy block in all of them"
fi

A0S=""
for f in $ALL_SITES; do
    if grep -q -E -e '\$REPO/\.\./fxstore' -e '\$REPO/\.\./datalog-dafsa' \
                 -e 'FX_INIT_REPO:-\(cd "\$REPO/\.\.' -e '^SIBS="\$\(cd "\$REPO/\.\."' "$f"; then
        A0S="unguarded \$REPO/.. sibling spelling still present in $f"; break
    fi
done
if [ -n "$A0S" ]; then
    bad A0 static "no stale sibling spelling" "$A0S"
else
    arm A0 static "no stale sibling spelling" "no unguarded \$REPO/.. resolution remains"
fi

# ═══ A1 · THE ASYMMETRY (P1) + P2(a) for the three host-side gates ═══════
# Pre-fix script (from PIN_REV), run from a checkout-shaped mirror whose parent
# IS the historical sibling root: it must SKIP, naming $OLD.  The working-tree
# script with no env override must NOT skip: it must reach its real verdict.
# A verdict of FAILURE is a FINDING (reported loudly) — never a reason to
# weaken this arm to get green.
for f in $HOST_GATES; do
    b="$(basename "$f")"
    git show "$PIN_REV:$f" >"$W/pin/$b" 2>"$W/pin/$b.err" \
        || { bad "A1-pin" "$b" "git show $PIN_REV:$f failed"; continue; }
    [ -s "$W/pin/$b" ] || { bad "A1-pin" "$b" "pinned script is empty"; continue; }
    if cmp -s "$W/pin/$b" "$f"; then
        bad "A1-pin" "$b" "VACUOUS PIN: $PIN_REV:$f is byte-identical to the working script"
        continue
    fi
    # mirror: every top-level entry of $REPO, and every entry of tests/ except
    # the three pinned names (copied in from the pin below).
    for e in "$REPO"/*; do
        n="$(basename "$e")"; [ "$n" = tests ] && continue
        [ -e "$MIRROR/$n" ] || ln -s "$e" "$MIRROR/$n"
    done
    for e in "$REPO"/tests/*; do
        n="$(basename "$e")"
        case "$n" in test_osier_share.sh|test_fx_report.sh|test_fx_audit.sh) continue ;; esac
        [ -e "$MIRROR/tests/$n" ] || ln -s "$e" "$MIRROR/tests/$n"
    done
    cp "$W/pin/$b" "$MIRROR/tests/$b" || { bad "A1-pin" "$b" "cannot stage the pinned copy"; continue; }

    o="$W/pre-$b.out"
    timeout -k 5 "$TIMEOUT_PREFIX" sh "$MIRROR/tests/$b" >"$o" 2>&1
    rc=$?
    hit="$(stale_hit "$o")"
    if [ "$rc" != 77 ]; then
        bad "A1-pre" "$b" "pre-fix run did not SKIP (exit $rc) — the pin is not a pre-fix script"
    elif [ -z "$hit" ]; then
        bad "A1-pre" "$b" "pre-fix run skipped but named no stale sibling path"
    else
        arm "A1-pre" "$b" "exit 77, names $hit — $(grep -m1 'SKIP (' "$o" | cut -c1-60)"
    fi

    o="$W/fix-$b.out"
    NOOVERRIDE timeout -k 5 "$TIMEOUT_HOST" sh "$f" >"$o" 2>&1
    rc=$?
    hit="$(stale_hit "$o")"
    if [ -n "$hit" ]; then
        bad "A1-fix" "$b" "still resolves to the stale sibling path $hit (exit $rc)"
    elif [ "$rc" = 77 ]; then
        bad "A1-fix" "$b" "SKIPPED, but not on the stale path: $(grep -m1 'SKIP (' "$o" | cut -c1-70)"
    else
        arm "A1-fix" "$b" "no skip, exit $rc — $(where "$o" "$rc" "$TIMEOUT_HOST")"
        case "$rc" in 0|124|137) ;;   # a bound is not verdict
            *) note "FINDING (A1-fix) $b: it RUNS now and reaches its real verdict, exit $rc — $(grep -m1 -E 'FAIL' "$o" | cut -c1-160)" ;;
        esac
    fi
done

# ═══ A2 · (P2b) FX_SIBLINGS is LIVE on every site: a bogus one must SKIP ══
# With FX_SIBLINGS=/nonexistent every site must exit 77 NAMING it.  A copy that
# ignores FX_SIBLINGS never skips here — it falls back to the real stack and
# runs on — so this arm is what fails such a copy.
for f in $ALL_SITES; do
    b="$(basename "$f")"
    o="$W/bogus-$b.out"
    env FX_SIBLINGS=/nonexistent timeout -k 5 "$TIMEOUT_PREFIX" sh "$f" >"$o" 2>&1
    rc=$?
    if [ "$rc" != 77 ]; then
        bad "A2-live" "$b" "FX_SIBLINGS=/nonexistent did not SKIP (exit $rc) — the override is not honoured"
    elif ! grep -q -F -- '/nonexistent' "$o"; then
        bad "A2-live" "$b" "skipped (exit 77) but does not name /nonexistent: $(grep -m1 'SKIP (' "$o" | cut -c1-70)"
    else
        arm "A2-live" "$b" "exit 77, names /nonexistent — $(grep -m1 'SKIP (' "$o" | cut -c1-60)"
    fi
done

# ═══ A4 · (P3) end to end: the host-side gates run the fixture machinery ══
# DATALOG_DIR is supplied because the Makefile's `DATALOG_DIR ?= ../datalog-dafsa`
# (line 39) is OUT OF THIS UNIT'S SCOPE and refuses the internal `make` those
# gates run; supplying it isolates that one residual blocker.  At least one of
# the three must exit 0, or this gate FAILS with that as its headline finding.
E2E_OK=0
for f in $HOST_GATES; do
    b="$(basename "$f")"
    o="$W/e2e-$b.out"
    env -u FX_SIBLINGS -u FXSTORE_BIN -u FX_INIT_REPO -u FXSTORE_REPO \
        DATALOG_DIR="$NEW/datalog-dafsa" \
        timeout -k 5 "$TIMEOUT_HOST" sh "$f" >"$o" 2>&1
    rc=$?
    if [ "$rc" = 0 ]; then
        E2E_OK=$((E2E_OK + 1))
        arm "A4-e2e" "$b" "exit 0 — $(grep -m1 'PASS' "$o" | cut -c1-70)"
    else
        arm "A4-e2e" "$b" "exit $rc — $(where "$o" "$rc" "$TIMEOUT_HOST")"
        case "$rc" in 124|137) ;;      # a bound is not a verdict
            *) note "FINDING (A4-e2e) $b: exit $rc with DATALOG_DIR supplied — $(grep -m1 -E 'FAIL' "$o" | cut -c1-160)" ;;
        esac
    fi
done
if [ "$E2E_OK" = 0 ]; then
    bad "A4-e2e" "host-side gates" "NO host-side gate ran to completion — this is the headline finding"
else
    arm "A4-e2e" "host-side gates" "$E2E_OK/3 exit 0 — the fixture machinery works in the new layout"
fi

# ═══ A5 · (P2a) tools/stage-guest.sh, no override, to completion ══════════
o="$W/stage.out"
NOOVERRIDE timeout -k 5 "$TIMEOUT_STAGE" sh tools/stage-guest.sh >"$o" 2>&1
rc=$?
hit="$(stale_hit "$o")"
if [ -n "$hit" ]; then
    bad "A5-tool" "stage-guest.sh" "resolves to the stale sibling path $hit (exit $rc)"
elif [ "$rc" = 0 ]; then
    arm "A5-tool" "stage-guest.sh" "exit 0 — ran to completion, no stale sibling path"
elif [ "$rc" = 77 ]; then
    arm "A5-tool" "stage-guest.sh" "exit 77 — SKIP at a later prerequisite: $(grep -m1 'SKIP (' "$o" | cut -c1-60)"
else
    bad "A5-tool" "stage-guest.sh" "exit $rc — $(where "$o" "$rc" "$TIMEOUT_STAGE")"
fi

# ═══ A6 · (P2a) the six qemu gates, no override, bounded ═════════════════
# EXPECTED on this host: each gets PAST resolution (its kernel block reads
# $INIT/.kernel-cache, i.e. the resolved stack) and then stops at this run's
# bound or at a later failure.  Asserted: the stale sibling path appears
# NOWHERE.  The stop reason is reported per gate — not a failure, and not
# dressed up as more than it is.
for f in $QEMU_GATES; do
    b="$(basename "$f")"
    o="$W/qemu-$b.out"
    NOOVERRIDE timeout -k 5 "$TIMEOUT_QEMU" env TMPDIR="$W/tmp" sh "$f" >"$o" 2>&1
    rc=$?
    hit="$(stale_hit "$o")"
    if [ -n "$hit" ]; then
        bad "A6-qemu" "$b" "names the stale sibling path $hit (exit $rc)"
    else
        arm "A6-qemu" "$b" "no stale path, exit $rc — $(where "$o" "$rc" "$TIMEOUT_QEMU")"
    fi
done

echo
if [ -s "$NOTES" ]; then
    echo "FINDINGS (loud, reported not fixed — this unit resolves paths and nothing else):"
    cat "$NOTES"
    echo
fi
if [ "$FAILED" != 0 ]; then
    echo "test_sibling_paths: FAIL — $FAILED of $NARM arms failed"
    exit 1
fi
echo "test_sibling_paths: PASS — $NARM arms, every site resolves its siblings by the one policy, and the stale $OLD path decides nothing"
exit 0
