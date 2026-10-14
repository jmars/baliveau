#!/bin/sh
# tests/test_claim_policy.sh -- THE GATE for the claim unit's S0: the
# agent-facing CLOSED LEXICON, the FROZEN POLICY, and the FREE-LE EVALUATOR.
#
# The whole unit rests on ONE property, and every arm below is a scene in
# which the WRONG implementation answers DIFFERENTLY:
#
#   THE SOUNDNESS BOUNDARY IS THE JUDGMENT PREDICATE `justified`.  The agent
#   gets FREE LE over a CLOSED, host-declared lexicon (it composes premises
#   and its own intermediate rules); `justified` is not in that lexicon and
#   is derivable only by the host's frozen policy.  Round 1's CHECKER was
#   overturned for exactly this: crippling the agent to avoid executing LE is
#   the runtime picking the language boundary.
#
# An arm that cannot fail is not an arm, so FOUR of them are paired with a
# MUTANT that goes blind on EXACTLY its own fixture (a `cmp` guard makes a sed
# that matches nothing FAIL the gate instead of comparing a file to itself):
#
#   A6a/A6b  the LEXICON mutant ADDS `justified` to the agent lexicon: the
#            hostile claim then gets PAST the compiler (a different refusal is
#            named) -- the boundary IS the lexicon closure, not the fixture --
#            and with the head check ALSO dropped the agent DERIVES `justified`
#            ITSELF.  That derivation is the breach the two checks prevent,
#            executed, not asserted.
#   A6d/A6e  the EVALUATOR mutant drops the head check: the head-forgery arm's
#            answer changes (refused -> derives) while the honest arm's does
#            NOT (it still derives), i.e. the mutant is blind on exactly its
#            fixture.
#   A7c      the POLICY mutant drops the differs guard: the vacuous-differs
#            arm then DERIVES, and the honest arm STOPS deriving -- the guard
#            is what refuses that claim, and it is blind on exactly it.
#   A10e     the PRE-FIX EVALUATOR mutant re-admits every relation in the
#            facts dump, `justified` included: the A10a arm flips
#            exit 2 (refused by name) -> exit 0 with rows=2 -- one row
#            justified(ghost), which no check named -- while the SAME mutant
#            on a clean dump still yields rows=1, i.e. it is blind on exactly
#            its fixture.  A10f reverts ONLY the dump typing and the
#            post-query symbol check refuses instead: the two changes are
#            independent layers, neither decoration.  The dump is the one
#            trusted-facts channel, so it is typed to the STORE templates --
#            the row bindings and the judgment predicate are the evaluator's.
#
# THE HOUSE ASYMMETRY (pre-fix control): the SAME instrument returns
# `verdict derives` for a claim with a path to the judgment rule (A3) and
# `justified-not-derived` for a vacuous one (A4) -- the non-derivation is a
# measurement, not a refusal-to-look.
#
# THE VACUITY RESTATEMENT.  Vacuity is a property of the POLICY and of where
# the boundary is drawn, NOT of a template set: an argument that never reaches
# the judgment rule justifies nothing, because `justified` is derivable only
# by the frozen policy's rule and the engine is a LEAST FIXPOINT -- zero
# derivation paths = zero rows = does-not-derive.  Arms: A4a unconnected
# argument (concludes an intermediate the policy never consumes), A4b
# self-loop ("I activate because I activate": no base case), A4c differs
# (S_from == the landed configuration: the guard is false), A4d premise-false
# (an asserted premise the store does not record as of from_version).
#
# `le` IS CONSUMED AS A DEPENDENCY from its own checkout (~/logical-english,
# $LE_DIR / $FX_SIBLINGS), never forked; the datalog engine is the sibling's
# dlb binding ($DLB_PATH), the tests' blessed engine path.
#
# STATED BOUNDS (printed on every run, never implicit):
#   * the evaluator runs HOST-SIDE today.  That is a DEPLOYMENT STOPGAP,
#     labelled: same lexicon, same policy, same claim bytes, same record --
#     only the evaluator's LOCATION differs (the committed target is in-guest,
#     x64-via-QBE in the qemu lane).  The location must never become a reason
#     to shrink the language; this gate compiles the SAME lexicon for both.
#   * le's proper nouns are letters-only (le/binding.py:144-159), so a REAL
#     sha256 symbol cannot be spelled today: the fixtures name their world and
#     a deployment generates [names] from the store.  A named residual.
set -u

fail() { echo "test_claim_policy: FAIL: $*" >&2; exit 1; }
skip() { echo "test_claim_policy: SKIP ($*)"; exit 77; }

cd "$(dirname "$0")/.." || fail "cannot cd to the repo root"
REPO="$PWD"

command -v python3 >/dev/null 2>&1 || fail "python3 is required (the le compiler and the evaluator are Python)"

# ── sibling resolution: the repo's ONE policy (tests/test_sibling_paths.sh).
#    FX_SIBLINGS is an explicit override and WINS; else the historical
#    neighbour $REPO/.. is kept only if it actually holds the stack; else the
#    relocated default.  `le` is a HARD dependency of this slice (the whole
#    unit is free LE over a closed lexicon), so its absence FAILS here rather
#    than skipping: a skip would read as a pass.
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
echo "test_claim_policy: le at $LE_ROOT; the engine binding at $DLB_PY"

EVAL="$REPO/policy/eval_claim.py"
LEX="$REPO/policy/claims-lexicon.ini"
POLICY="$REPO/policy/claims-policy.le"
PLEX="$REPO/policy/policy-lexicon.ini"
ART="$REPO/policy/claims-policy.dl"
PINS="$REPO/policy/PINS"
FIX="$REPO/tests/fixtures/claims"

for f in "$EVAL" "$LEX" "$POLICY" "$PLEX" "$ART" "$PINS"; do
    [ -f "$f" ] || fail "missing $f"
done

W="$REPO/build/claim-policy-gate"
rm -rf "$W"; mkdir -p "$W" || fail "cannot create $W"

SHA_A=$(printf '%064d' 0 | tr '0' 'a')   # the configuration the claim starts at
SHA_B=$(printf '%064d' 0 | tr '0' 'b')   # a DIFFERENT configuration, landed
SHA_C=$(printf '%064d' 0 | tr '0' 'c')

CL=(--lexicon "$LEX" --policy "$ART" --facts "$FIX/store.tsv")
PINNED=(--lexicon "$LEX" --policy "$ART" --facts "$FIX/store.tsv" --pins "$PINS")

arm() { # arm NAME WANT_RC PATTERN ARGS...
    name=$1; want=$2; pat=$3; shift 3
    out="$W/$name.txt"
    python3 "$EVAL" "$@" >"$out" 2>&1
    rc=$?
    [ "$rc" = "$want" ] || fail "arm $name: exit $rc, expected $want; record: $(grep -m1 verdict "$out" || head -2 "$out")"
    grep -q "$pat" "$out" || fail "arm $name: '$pat' absent from the record ($(grep -m1 verdict "$out"))"
    echo "test_claim_policy: OK $name (exit $rc, /$pat/)"
}

echo "test_claim_policy: ── A0 the agent-facing lexicon's boundary ──"
arm a0-lexicon-boundary 0 'judgment-in-agent-lexicon=absent' --lint-lexicon "$LEX"
# ...and the SAME check refuses a lexicon that declares the judgment predicate
# (it is the check, not the file, that holds the boundary).
sed -e 's@^\[predicates\]$@[predicates]\n<a claim C> is justified | justified | claim@' "$LEX" > "$W/mutant.ini"
cmp -s "$LEX" "$W/mutant.ini" && fail "the lexicon sed matched NOTHING (the mutant would be the original)"
grep -q '| justified |' "$W/mutant.ini" || fail "the lexicon mutant does not declare justified"
arm a0b-lexicon-mutant-refused 1 'boundary-reopened' --lint-lexicon "$W/mutant.ini"

echo "test_claim_policy: ── A1 the policy pin: determinism, artifact, sha ──"
python3 "$EVAL" --compile-policy --policy-le "$POLICY" --policy-lexicon "$PLEX" >"$W/policy.1" 2>"$W/policy.err" \
    || fail "compiling the frozen policy failed: $(cat "$W/policy.err")"
python3 "$EVAL" --compile-policy --policy-le "$POLICY" --policy-lexicon "$PLEX" >"$W/policy.2" 2>>"$W/policy.err" \
    || fail "the second policy compile failed: $(cat "$W/policy.err")"
cmp -s "$W/policy.1" "$W/policy.2" || fail "two policy compiles are NOT byte-identical (policy-pin determinism)"
grep -q '^justified(' "$W/policy.1" || fail "the policy artifact does not conclude justified"
cmp -s "$W/policy.1" "$ART" || fail "policy/claims-policy.dl is NOT the artifact a fresh compile produces -- regenerate it with 'make policy-artifact' and update policy/PINS in the same commit"
sha_art=$(sha256sum "$W/policy.1" | cut -d' ' -f1)
sha_pin=$(grep '^claims-policy\.dl' "$PINS" | cut -f2)
[ "$sha_art" = "$sha_pin" ] || fail "the pinned policy sha is $sha_pin, the artifact hashes to $sha_art -- the pin and the artifact have drifted"
sha_lex=$(sha256sum "$LEX" | cut -d' ' -f1)
[ "$sha_lex" = "$(grep '^claims-lexicon\.ini' "$PINS" | cut -f2)" ] || fail "the agent lexicon is not the pinned one"
sha_plex=$(sha256sum "$PLEX" | cut -d' ' -f1)
[ "$sha_plex" = "$(grep '^policy-lexicon\.ini' "$PINS" | cut -f2)" ] || fail "the policy lexicon is not the pinned one"
echo "test_claim_policy: OK a1-policy-pin (two compiles byte-identical, artifact + both lexicons match policy/PINS)"

echo "test_claim_policy: ── A2 the policy lint (heads, and the store spine) ──"
arm a2-policy-shipped 0 '^justified(C1) :- contention' --compile-policy --policy-le "$POLICY" --policy-lexicon "$PLEX"
arm a2b-policy-vacuous 1 'policy-vacuous' --compile-policy --policy-le "$FIX/policy-vacuous.le" --policy-lexicon "$PLEX"
arm a2c-policy-foreign-head 1 'policy-foreign-head' --compile-policy --policy-le "$FIX/policy-foreign-head.le" --policy-lexicon "$PLEX"

echo "test_claim_policy: ── A3 the claim WITH a path DERIVES ──"
arm a3-derives 0 'verdict	derives	justified(claima)	rows=1' \
    --claim "$FIX/good.tsv" --le "$FIX/good.le" --landed-config "$SHA_B" "${PINNED[@]}"
grep -q 'spine	generation_config(gena,' "$W/a3-derives.txt" || fail "a3: the record does not name the store spine it read"
grep -q 'guard	landed_config(.*	ABSENT' "$W/a3-derives.txt" || fail "a3: the differs guard should be ABSENT (the claim does start somewhere else)"

echo "test_claim_policy: ── A4 vacuity: four arguments that justify NOTHING ──"
arm a4a-unconnected 1 'justified-not-derived' \
    --claim "$FIX/good.tsv" --le "$FIX/vacuous-unconnected.le" --landed-config "$SHA_B" "${CL[@]}"
grep -q 'agent	facts=0	rules=2' "$W/a4a-unconnected.txt" || fail "a4a: expected TWO well-formed agent rules (the intermediate plus the second intermediate) -- the arm must be a valid argument, not noise"
arm a4b-selfloop 1 'justified-not-derived' \
    --claim "$FIX/good.tsv" --le "$FIX/vacuous-selfloop.le" --landed-config "$SHA_B" "${CL[@]}"
grep -q 'agent	facts=0	rules=1' "$W/a4b-selfloop.txt" || fail "a4b: expected the ONE self-referential rule (so the two arms are demonstrably different arguments)"
arm a4c-differs 1 'justified-not-derived' \
    --claim "$FIX/good.tsv" --le "$FIX/good.le" --landed-config "$SHA_A" "${CL[@]}"
grep -q 'guard	landed_config(.*	PRESENT' "$W/a4c-differs.txt" || fail "a4c: the guard must be PRESENT -- that is the cause of the non-derivation"
arm a4d-premise-false 1 'premise-false' \
    --claim "$FIX/good.tsv" --le "$FIX/premise-false.le" --landed-config "$SHA_B" "${CL[@]}"
# a4e: the premise verifier reads the STORE, not the claim's own word -- a
# premise about the claim row itself is checked BEFORE the row's bindings are
# injected, so an agent cannot certify its own from_version.  (Swapping those
# two steps is exactly what this arm catches.)
arm a4e-premise-selfsupport 1 'premise-false' \
    --claim "$FIX/good.tsv" --le "$FIX/premise-selfsupport.le" --landed-config "$SHA_B" "${CL[@]}"
grep -q "claim_from(claima, gena)" "$W/a4e-premise-selfsupport.txt" || fail "a4e: the refusal must name the self-certifying premise"

echo "test_claim_policy: ── A5 the hostile claim: the lexicon refuses it ──"
arm a5-hostile-compile 1 'hostile-compile' \
    --claim "$FIX/good.tsv" --le "$FIX/hostile.le" --landed-config "$SHA_B" "${CL[@]}"
grep -q 'ontology extension (the declared predicate set is closed)' "$W/a5-hostile-compile.txt" || \
    fail "a5: the refusal must quote le's own gap name, not paraphrase it"

echo "test_claim_policy: ── A6 mutants: each check proved able to fail ──"
sed -e 's@if pred not in AGENT_CONCLUSIONS:@if False:@' "$EVAL" > "$W/mutant_eval.py"
cmp -s "$EVAL" "$W/mutant_eval.py" && fail "the evaluator sed matched NOTHING (the mutant would be the original)"
grep -q 'if False:' "$W/mutant_eval.py" || fail "the evaluator mutant does not drop the head check"

# a6a: the mutant lexicon lets the HOSTILE claim compile -- the boundary is the
# lexicon closure, so what refuses it now is the head check.
arm a6a-mutant-lexicon-hostile 1 'head-forgery' \
    --claim "$FIX/good.tsv" --le "$FIX/hostile.le" --lexicon "$W/mutant.ini" --policy "$ART" --facts "$FIX/store.tsv" --landed-config "$SHA_B"
# a6b: THE BREACH, EXECUTED -- both checks gone, the agent derives `justified`
# itself.  This is why both checks exist.
python3 "$W/mutant_eval.py" --claim "$FIX/good.tsv" --le "$FIX/hostile.le" --lexicon "$W/mutant.ini" \
    --policy "$ART" --facts "$FIX/store.tsv" --landed-config "$SHA_B" >"$W/a6b.txt" 2>&1
rc=$?
[ "$rc" = 0 ] || fail "a6b: the double mutant did NOT derive justified (exit $rc) -- the breach the checks prevent could not be executed, so the arms above prove nothing"
grep -q 'verdict	derives	justified(claima)' "$W/a6b.txt" || fail "a6b: no derives row"
echo "test_claim_policy: OK a6b-double-mutant-breach (exit 0, the agent derived justified ITSELF -- the breach is executable, not hypothetical)"
# a6c/a6d: each mutant is BLIND on exactly that fixture.
arm a6c-mutant-lexicon-honest 0 'verdict	derives' \
    --claim "$FIX/good.tsv" --le "$FIX/good.le" --lexicon "$W/mutant.ini" --policy "$ART" --facts "$FIX/store.tsv" --landed-config "$SHA_B"
# the evaluator mutant is run as its own file (a3's fixture, unchanged)
python3 "$W/mutant_eval.py" --claim "$FIX/good.tsv" --le "$FIX/good.le" --lexicon "$LEX" \
    --policy "$ART" --facts "$FIX/store.tsv" --landed-config "$SHA_B" >"$W/a6d.txt" 2>&1
[ "$?" = 0 ] || fail "a6d: the evaluator mutant changed the honest arm's answer"
grep -q 'verdict	derives' "$W/a6d.txt" || fail "a6d: no derives row"
echo "test_claim_policy: OK a6d-mutant-eval-honest (the head-check mutant is blind on the honest arm)"
python3 "$W/mutant_eval.py" --claim "$FIX/good.tsv" --le "$FIX/head-forgery.le" --lexicon "$LEX" \
    --policy "$ART" --facts "$FIX/store.tsv" --landed-config "$SHA_B" >"$W/a6e.txt" 2>&1
[ "$?" = 0 ] || fail "a6e: the evaluator mutant still refused the head-forgery claim"
grep -q 'verdict	derives' "$W/a6e.txt" || fail "a6e: the head-check mutant did not let the head-forgery arm through"
echo "test_claim_policy: OK a6e-mutant-eval-head-forgery (the arm's answer flips: refused -> derives)"

echo "test_claim_policy: ── A7 the pins, and the guard's own mutant ──"
arm a7a-stale-lexicon 1 'stale-lexicon' \
    --claim "$FIX/good.tsv" --le "$FIX/good.le" --lexicon "$W/mutant.ini" --policy "$ART" \
    --facts "$FIX/store.tsv" --landed-config "$SHA_B" --pins "$PINS"
sed -e 's@!landed_config(C2)@landed_config(C2)@' "$ART" > "$W/mutant_policy.dl"
cmp -s "$ART" "$W/mutant_policy.dl" && fail "the policy sed matched NOTHING (the mutant would be the original)"
arm a7b-stale-policy 1 'stale-policy' \
    --claim "$FIX/good.tsv" --le "$FIX/good.le" --landed-config "$SHA_B" \
    --lexicon "$LEX" --policy "$W/mutant_policy.dl" --facts "$FIX/store.tsv" --pins "$PINS"
# a7c: the guard-dropped policy DERIVES the differs claim -- and STOPS deriving
# the honest one.  Blind on exactly the differs fixture.
python3 "$EVAL" --claim "$FIX/good.tsv" --le "$FIX/good.le" --landed-config "$SHA_A" \
    --lexicon "$LEX" --policy "$W/mutant_policy.dl" --facts "$FIX/store.tsv" >"$W/a7c.txt" 2>&1
[ "$?" = 0 ] || fail "a7c: the guard-dropped policy did not derive the differs claim -- the guard is not what refuses it"
grep -q 'verdict	derives' "$W/a7c.txt" || fail "a7c: no derives row"
echo "test_claim_policy: OK a7c-guard-mutant-differs (the vacuous-differs arm PASSES once the guard is gone)"
python3 "$EVAL" --claim "$FIX/good.tsv" --le "$FIX/good.le" --landed-config "$SHA_B" \
    --lexicon "$LEX" --policy "$W/mutant_policy.dl" --facts "$FIX/store.tsv" >"$W/a7d.txt" 2>&1
[ "$?" = 1 ] || fail "a7d: the guard-dropped policy also derived the honest claim -- the mutant is NOT blind on the differs fixture"
grep -q 'justified-not-derived' "$W/a7d.txt" || fail "a7d: no refusal row"
echo "test_claim_policy: OK a7d-guard-mutant-honest (the honest arm stops deriving: the mutant is blind on exactly its fixture)"
arm a7e-pinned-honest 0 'verdict	derives' \
    --claim "$FIX/good.tsv" --le "$FIX/good.le" --landed-config "$SHA_B" --pins "$PINS" \
    --lexicon "$LEX" --policy "$ART" --facts "$FIX/store.tsv"
# a7f: a HALF pin is refused -- otherwise the file it does not name would go
# unverified while the record still showed a sha.
grep -v '^claims-lexicon\.ini' "$PINS" > "$W/half-pins"
cmp -s "$PINS" "$W/half-pins" && fail "the pins sed matched NOTHING"
arm a7f-pin-incomplete 1 'pin-incomplete' \
    --claim "$FIX/good.tsv" --le "$FIX/good.le" --landed-config "$SHA_B" --pins "$W/half-pins" \
    --lexicon "$LEX" --policy "$ART" --facts "$FIX/store.tsv"

echo "test_claim_policy: ── A8 the claim row is validated LOUDLY ──"
arm a8a-malformed-claim 1 'malformed-claim' \
    --claim "$FIX/malformed.tsv" --le "$FIX/good.le" --landed-config "$SHA_B" "${CL[@]}"
arm a8b-undeclared-claim-id 1 'undeclared-claim-id' \
    --claim "$FIX/undeclared.tsv" --le "$FIX/good.le" --landed-config "$SHA_B" "${CL[@]}"
arm a8c-tool-error-no-facts 2 'TOOL ERROR' \
    --claim "$FIX/good.tsv" --le "$FIX/good.le" --lexicon "$LEX" --policy "$ART" --landed-config "$SHA_B"
# a8d: the frozen column-kind table is READ, not decorative -- install's third
# column is raw-u32 in the store's schema, so a non-integer there is a TOOL
# ERROR (the dump is malformed), never a silently interned symbol.
sed -e 's@	420	@	not-a-number	@' "$FIX/store.tsv" > "$W/bad-raw.tsv"
cmp -s "$FIX/store.tsv" "$W/bad-raw.tsv" && fail "the dump sed matched NOTHING"
arm a8d-tool-error-bad-raw 2 'raw-u32' \
    --claim "$FIX/good.tsv" --le "$FIX/good.le" --landed-config "$SHA_B" \
    --lexicon "$LEX" --policy "$ART" --facts "$W/bad-raw.tsv"

echo "test_claim_policy: ── A9 what the agent's vocabulary can actually consume ──"
# a9a: a SECOND store template consumed in a body (provides: two different
# sorts) -- the agent's argument really does read the store spine.
arm a9a-provides-body 0 'verdict	derives' \
    --claim "$FIX/good.tsv" --le "$FIX/provides-body.le" --landed-config "$SHA_B" "${CL[@]}"
# a9b: THE MEASURED LIMIT OF TODAY'S VOCABULARY, and it is LOUD: install's
# first two columns are both sort `path`, and le permits one unanchored
# `a <noun>` binding per sort per clause, so the USEFUL install shape cannot
# be written.  The refusal is le's own named gap, never a silent drop.
arm a9b-install-two-paths-loud 1 'compile-refused' \
    --claim "$FIX/good.tsv" --le "$FIX/install-two-paths.le" --landed-config "$SHA_B" "${CL[@]}"
grep -q 'second unanchored binding of sort' "$W/a9b-install-two-paths-loud.txt" || \
    fail "a9b: the install limitation must be refused BY NAME (le's repeat-sort gap), not silently dropped"
grep -q 'install' "$W/a9b-install-two-paths-loud.txt" || fail "a9b: the refusal must name the template at fault"
echo "test_claim_policy: OK a9b (install's two same-sort columns cannot be written by an agent TODAY — stated, and loud)"

echo "test_claim_policy: ── A10 the facts dump carries STORE FACTS ONLY ──"
# The dump is this evaluator's ONE trusted-facts channel, so it is TYPED: it
# may name a store template and nothing else.  RELATIONS is the union of the
# store templates, the row bindings the evaluator injects (claim_from /
# claim_config / landed_config) and the judgment predicate ITSELF -- admitting
# any of the latter would let the dump feed the goal, i.e. the verdict would
# rest on a row the subject could have asserted.  Arms below prove the typing
# is real, and A10e executes the PRE-FIX evaluator to show the arm can fail.
printf 'justified\tghost\n' > "$W/justified-in-dump.tsv"
cat "$FIX/store.tsv" "$W/justified-in-dump.tsv" > "$W/breach-dump.tsv"
[ "$(wc -l < "$W/breach-dump.tsv")" = 4 ] || fail "the breach dump is not store.tsv + one row"
arm a10a-dump-justified-refused 2 'not a store template' \
    --claim "$FIX/good.tsv" --le "$FIX/good.le" --landed-config "$SHA_B" \
    --lexicon "$LEX" --policy "$ART" --facts "$W/breach-dump.tsv"
grep -q "names the relation 'justified'" "$W/a10a-dump-justified-refused.txt" || \
    fail "a10a: the refusal must NAME the relation the dump carried"
# ...and the SAME gate refuses the evaluator's own injected row bindings: the
# dump may not supply the spine the evaluator is supposed to derive from the
# claim row.
printf 'claim_from\tclaima\tgena\n' > "$W/claimfrom-in-dump.tsv"
cat "$FIX/store.tsv" "$W/claimfrom-in-dump.tsv" > "$W/breach-claimfrom.tsv"
arm a10b-dump-rowbinding-refused 2 'not a store template' \
    --claim "$FIX/good.tsv" --le "$FIX/good.le" --landed-config "$SHA_B" \
    --lexicon "$LEX" --policy "$ART" --facts "$W/breach-claimfrom.tsv"
grep -q "names the relation 'claim_from'" "$W/a10b-dump-rowbinding-refused.txt" || \
    fail "a10b: the refusal must name claim_from"
# ...while a dump of REAL store facts is still read: the typing refused the
# judgment predicate, not the channel.
arm a10c-dump-store-facts-ok 0 'verdict	derives	justified(claima)	rows=1' \
    --claim "$FIX/good.tsv" --le "$FIX/good.le" --landed-config "$SHA_B" "${CL[@]}"

# THE ARM CAN FAIL.  The PRE-FIX evaluator (both changes reverted: the dump
# admits anything in RELATIONS, and the verdict does not check which symbols
# the rows carry) ADMITS the breach dump and exits 0 with rows=2 -- one of
# them justified(ghost) -- while remaining BLIND on the clean dump (rows=1).
sed -e 's@if relation not in STORE_TEMPLATES:@if relation not in RELATIONS:@' "$EVAL" > "$W/mutant_dump_pre.py"
cmp -s "$EVAL" "$W/mutant_dump_pre.py" && fail "the dump-typing sed matched NOTHING (the mutant would be the original)"
grep -q 'if relation not in RELATIONS:' "$W/mutant_dump_pre.py" || fail "the pre-fix mutant does not re-admit RELATIONS"
sed -i -e 's@^        if foreign:$@        if False:@' "$W/mutant_dump_pre.py"
grep -q '^        if False:$' "$W/mutant_dump_pre.py" || fail "the pre-fix mutant does not disable the symbol check"
python3 "$W/mutant_dump_pre.py" --claim "$FIX/good.tsv" --le "$FIX/good.le" --landed-config "$SHA_B" \
    --lexicon "$LEX" --policy "$ART" --facts "$FIX/store.tsv" >"$W/a10d.txt" 2>&1
[ "$?" = 0 ] || fail "a10d: the pre-fix mutant changed the CLEAN arm's answer -- it is not blind on exactly its fixture"
grep -q 'verdict	derives	justified(claima)	rows=1' "$W/a10d.txt" || fail "a10d: the clean dump did not yield exactly one row"
python3 "$W/mutant_dump_pre.py" --claim "$FIX/good.tsv" --le "$FIX/good.le" --landed-config "$SHA_B" \
    --lexicon "$LEX" --policy "$ART" --facts "$W/breach-dump.tsv" >"$W/a10e.txt" 2>&1
[ "$?" = 0 ] || fail "a10e: the pre-fix evaluator did NOT admit the justified row -- the arm cannot fail, so it proves nothing"
grep -q 'verdict	derives	justified(claima)	rows=2' "$W/a10e.txt" || fail "a10e: the pre-fix evaluator did not derive the foreign row"
grep -q 'facts	store-rows=4' "$W/a10e.txt" || fail "a10e: the pre-fix evaluator did not even STORE the fourth (justified) row"
grep -q 'facts	store-rows=3' "$W/a10d.txt" || fail "a10d: the clean dump should be three rows"
grep -q 'verdict' "$W/a10a-dump-justified-refused.txt" && fail "a10a: a dump the gate refuses must not reach a verdict line"
echo "test_claim_policy: OK a10e-prefix-mutant-admits (exit 0, rows=2 -- the PRE-FIX evaluator admits a \`justified\` row from the dump and the verdict names only the claim)"
# A10f: the SECOND layer independently catches what the first admits.  With
# ONLY the dump typing reverted, the row gets in and the post-query symbol
# check -- not the dump gate -- is what refuses; so neither change is
# decoration, and the record can never name a claim the rows do not support.
sed -e 's@if relation not in STORE_TEMPLATES:@if relation not in RELATIONS:@' "$EVAL" > "$W/mutant_dump_a.py"
grep -q 'if relation not in RELATIONS:' "$W/mutant_dump_a.py" || fail "the dump-typing-only mutant is identical to the original"
python3 "$W/mutant_dump_a.py" --claim "$FIX/good.tsv" --le "$FIX/good.le" --landed-config "$SHA_B" \
    --lexicon "$LEX" --policy "$ART" --facts "$W/breach-dump.tsv" >"$W/a10f.txt" 2>&1
rc=$?
[ "$rc" = 2 ] || fail "a10f: with only the dump typing reverted the run exited $rc, expected 2 (the symbol check is the second layer)"
grep -q 'derived for symbols other than' "$W/a10f.txt" || fail "a10f: the second layer did not name the foreign row"
echo "test_claim_policy: OK a10f-symbol-check-second-layer (dump typing reverted alone -> the post-query check refuses by name)"

echo "test_claim_policy: BOUND — the evaluator runs HOST-SIDE (a labelled DEPLOYMENT stopgap: same lexicon, same policy, same claim bytes, same record; the committed target is in-guest via the Osier x64/QBE path, S3a)."
echo "test_claim_policy: BOUND — le proper nouns are letters-only (le/binding.py:144-159), so a real sha256 symbol cannot be spelled TODAY; the fixtures name their world and a deployment generates [names] from the store."
echo "test_claim_policy: BOUND — of the three store templates, generation_config and provides are fully consumable in a body (distinct sorts); install is NOT (its first two columns are both sort path, and le allows one unanchored binding per sort per clause) — measured and refused by name in a9b, not hidden. S3's port owns it."
echo "test_claim_policy: BOUND — the claim's from_version is bound to the row's injected claim_from/claim_config here; the cross-check against the .operator row and the landed generation is the C seat's (S1, tools/fx-claim.c), which this slice does not build."
echo "test_claim_policy: BOUND — the row's config-diff field is carried into the record and read by NO check: the judgment binds from_version and S_from only. Stated so the field is never mistaken for something that was judged."
echo "test_claim_policy: PASS — the boundary is the judgment predicate: the closed lexicon refuses the hostile claim, the head check refuses the forged spine, the guard refuses the differs claim, the premises are checked against the store, and each of those checks is proved able to FAIL."
exit 0
