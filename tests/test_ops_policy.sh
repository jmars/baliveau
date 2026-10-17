#!/bin/sh
# tests/test_ops_policy.sh -- THE GATE for the OPS-POLICY unit's S1: the
# OPERATOR-POLICY LEXICON, the OPERATOR POLICY (D1 + D2), the PINNED ALIAS
# TABLE and the release tool (policy/ops/eval_ops.py).  NO server change in
# this slice: the enforcement seat at the verbs server's commit sites is S2.
#
# The whole unit rests on ONE property, and every arm below is a scene in
# which the WRONG implementation answers DIFFERENTLY:
#
#   THE AUTHOR IS THE OPERATOR, AND THE POLICY IS DENY-MORE-ONLY.  Every head
#   of the frozen policy is `denied`; `justified` (the claim unit's judgment
#   predicate) is not in the ops lexicon, and the claim lexicons never
#   declare `denied` -- that mutual ABSENCE is the two-author boundary, and
#   each side's closure refuses the other's predicate by le's own named gap.
#
#   THE VOCABULARY SEAM (MEASURED: le proper nouns are letters-only,
#   le/lexicon.py:157-159, and fold to lowercased symbols).  A policy that
#   naively spells a runtime symbol either fails lexicon load (LOUD, b5a) or
#   -- worse -- compiles, lints, pins and matches NOTHING: A SILENT
#   ALLOW-ALL (b5b executes exactly that with `Fxwrite`, and b5c does it
#   through a typo'd alias pattern with the pin honestly re-taken, which the
#   pin CANNOT catch).  The SAME trap exists in the alias table's PATTERN
#   grammar (MEASURED, S1 review: patterns are fnmatch GLOBS, EXACT, NEVER
#   PREFIXES -- a bare directory row passes a pure absoluteness check and
#   then protects nothing but the node): the grammar is now TWO STATED FORMS
#   enforced at pin time (exact, or '<path>/**' subtree -- b0g refuses the
#   ambiguous shapes), the subtree form is shown to cover node AND
#   descendants end to end (b5d), and the bare-dir row's exact-only
#   under-protection is executed and pinned (b5e).  The catch is still the
#   deny-direction arms: b4a asserts the denial IS derived, and that
#   assertion is what fails under every silent mutant.
#
#   THE BOOT CONDITION FAILS CLOSED: D2 negates the injected boot_verdict(ok)
#   fact, so an ABSENT verdict (b4c) and a DIFFERENT verdict atom --
#   boot_verdict(failed), the degraded-boot shape (b4e) -- both deny.
#
# THE ASYMMETRY, stated: these arms cannot exist pre-change -- the artifact
# is new, so there is nothing to mutate for a pre-fix control.  The control
# this slice offers is that the claim unit's own gates (`make
# test-claim-policy`, `make test-claim`) stay UNTOUCHED and GREEN: this
# slice shares the claim machinery (le dependency, pin discipline, evaluator
# pattern) and must not disturb the judgment predicate it shares it with.
#
# FAILURE DIRECTIONS, named per arm (a silent deny-all and a silent allow-all
# are DIFFERENT defects):
#   deny-all   b4b/b4d assert ZERO rows on unprotected/unscoped facts; the
#              b6b mutant (D2's boot condition dropped -- an unconditional
#              writable denial) flips b4b 0 -> 1 and is blind on exactly it.
#   allow-all  b4a/b4c/b4e assert the denial IS derived; the b5b/b5c/b6a
#              mutants (naive spelling, typo'd alias pattern, D1's protected
#              atom dropped) each flip a denial to zero rows on exactly its
#              fixture, and b5e pins the boundary the OTHER way: a bare dir
#              row must NOT deny the grandchild (glob-less is never a
#              prefix -- a prefix-matching "fix" flips b5e), while b5d
#              asserts the /** spelling DOES deny node and descendants.
#
# `le` IS CONSUMED AS A DEPENDENCY from its own checkout ($LE_DIR /
# $FX_SIBLINGS), never forked; the engine is the sibling's dlb binding
# ($DLB_PATH), driven directly by the gate's fixture driver ($W/driver.py),
# which performs the seat's startup resolve in miniature: the pinned alias
# table's patterns are matched against the paths the facts serve, and the
# class/protected binding facts are injected FROM THE TABLE -- so the
# deny-direction arms are anchored to the real pinned artifact, not to a
# hand-copied fixture.
set -u

fail() { echo "test_ops_policy: FAIL: $*" >&2; exit 1; }

cd "$(dirname "$0")/.." || fail "cannot cd to the repo root"
REPO="$PWD"

command -v python3 >/dev/null 2>&1 || fail "python3 is required (the le compiler and the release tool are Python)"

# -- sibling resolution: the repo's ONE policy (tests/test_sibling_paths.sh).
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
    fail "no datalog-dafsa python binding (set DLB_PATH); the deny-direction arms need dlb"
export DLB_PATH="$DLB_PY"
echo "test_ops_policy: le at $LE_ROOT; the engine binding at $DLB_PY"

OPS="$REPO/policy/ops"
EVAL="$OPS/eval_ops.py"
LEX="$OPS/ops-lexicon.ini"
POLICY="$OPS/ops-policy.le"
TSV="$OPS/ops-aliases.tsv"
HOSTS="$OPS/ops-hosts.tsv"
ART="$OPS/ops-policy.dl"
PINS="$OPS/PINS"
FIX="$REPO/tests/fixtures/ops"
CLAIMS_LEX="$REPO/policy/claims-lexicon.ini"
CLAIMS_PLEX="$REPO/policy/policy-lexicon.ini"

for f in "$EVAL" "$LEX" "$POLICY" "$TSV" "$HOSTS" "$ART" "$PINS" \
         "$FIX/policy-vacuous.le" "$FIX/policy-foreign-head.le" \
         "$FIX/naive-spelling.le" "$FIX/ops-sentence-justified.le" \
         "$FIX/claims-sentence-denied.le" "$FIX/deny-protected-ok.tsv" \
         "$FIX/deny-data-ok.tsv" "$FIX/deny-data-noboot.tsv" \
         "$FIX/deny-data-bootfailed.tsv" "$FIX/deny-data-sub-ok.tsv" \
         "$FIX/read-protected-ok.tsv" "$FIX/deny-hostcat-protected.tsv" \
         "$FIX/deny-hostcat-data.tsv" "$CLAIMS_LEX" "$CLAIMS_PLEX"; do
    [ -f "$f" ] || fail "missing $f"
done

W="$REPO/build/ops-policy-gate"
rm -rf "$W"; mkdir -p "$W" || fail "cannot create $W"

# -- the fixture driver: the seat's startup resolve in miniature, over the
#    REAL pinned alias table.  Declares exactly the closed relation set,
#    injects class/protected from the table (patterns matched against the
#    paths the fact set serves), adds the fact rows, queries `denied`.
cat > "$W/driver.py" <<'PYEOF'
import argparse, fnmatch, os, shutil, sys, tempfile
sys.path.insert(0, os.environ["DLB_PATH"])
import dlb

p = argparse.ArgumentParser()
p.add_argument("--policy", required=True)
p.add_argument("--aliases", required=True)
p.add_argument("--facts", required=True)
a = p.parse_args()

REL = {"denied": 2, "touches": 2, "kind": 2, "class": 2,
       "protected": 1, "writable": 1, "hosttool": 1, "boot_verdict": 1}
d = tempfile.mkdtemp(prefix="fx-ops-gate-")
db = dlb.Db.open(d)
for n, ar in REL.items():
    db.declare_relation(n, ar)
intern = db.intern

rows = []
for line in open(a.aliases):
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    alias, pathclass, protected, pattern = line.split("\t")
    rows.append((alias.lower(), pathclass.lower(), protected, pattern))

def pattern_hits(pattern, paths):
    # The TWO-FORM grammar --check-aliases enforces, implemented for the
    # resolve: an EXACT pattern (glob-less) matches that path ONLY — never a
    # prefix; a SUBTREE '<path>/**' matches the node ITSELF and every
    # descendant (fnmatch's '*' spans '/', so base + "/*" is the whole
    # subtree below the node).  S2's seat must implement the same grammar.
    if pattern.endswith("/**"):
        base = pattern[:-3]
        return [q for q in paths
                if q == base or fnmatch.fnmatchcase(q, base + "/*")]
    return [q for q in paths if fnmatch.fnmatchcase(q, pattern)]

facts = []
for line in open(a.facts):
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    facts.append(line.split("\t"))

# the paths the fact set serves (the seat resolves against the verb rows)
paths = sorted({f[2] for f in facts if f[0] == "touches"}
               | {f[1] for f in facts if f[0] == "writable"}
               | {f[1] for f in facts if f[0] == "class"})
n_class = n_prot = 0
for alias, pathclass, protected, pattern in rows:
    hit = pattern_hits(pattern, paths)
    for q in hit:
        db.add_fact("class", (intern(q), intern(pathclass)))
        n_class += 1
    if protected == "yes" and hit:
        db.add_fact("protected", (intern(pathclass),))
        n_prot += 1

for f in facts:
    rel = f[0]
    if rel not in REL:
        sys.exit("unknown relation " + rel)
    db.add_fact(rel, tuple(intern(x) for x in f[1:]))

policy = open(a.policy).read()
got = list(db.query_rules_ro(policy, "denied"))
named = sorted("(" + ", ".join(db.sym_of(c) for c in r) + ")" for r in got)
print("resolved\tclass-facts=%d\tprotected-facts=%d" % (n_class, n_prot))
print("rows=%d" % len(got))
for t in named:
    print("denied" + t)
shutil.rmtree(d, ignore_errors=True)
PYEOF

arm() { # arm NAME WANT_RC PATTERN ARGS...
    name=$1; want=$2; pat=$3; shift 3
    out="$W/$name.txt"
    python3 "$EVAL" "$@" >"$out" 2>&1
    rc=$?
    [ "$rc" = "$want" ] || fail "arm $name: exit $rc, expected $want; record: $(grep -m1 verdict "$out" || head -2 "$out")"
    grep -q "$pat" "$out" || fail "arm $name: '$pat' absent from the record ($(head -3 "$out"))"
    echo "test_ops_policy: OK $name (exit $rc, /$pat/)"
}

deny_arm() { # deny_arm NAME FACTS WANT_ROWS [WANT_ROW]
    name=$1; fx=$2; want=$3; wantrow=${4:-}
    out="$W/$name.txt"
    python3 "$W/driver.py" --policy "$ART" --aliases "$TSV" --facts "$fx" >"$out" 2>&1
    rc=$?
    [ "$rc" = 0 ] || fail "arm $name: the driver exited $rc: $(cat "$out")"
    grep -q "^rows=$want\$" "$out" || fail "arm $name: expected rows=$want, got $(grep '^rows=' "$out")"
    if [ -n "$wantrow" ]; then
        grep -qF "denied$wantrow" "$out" || fail "arm $name: the denial row 'denied$wantrow' is absent ($(grep '^denied' "$out" || echo none))"
    fi
    echo "test_ops_policy: OK $name (rows=$want${wantrow:+, denied$wantrow})"
}

echo "test_ops_policy: -- B0 the pinned alias table: validated, loudly --"
arm b0-aliases-ok 0 'alias table OK' --check-aliases --aliases "$TSV" --policy-lexicon "$LEX"
# b0b: an alias the lexicon does not declare -- refused, never silently
# unmatched (the allow-all direction an unknown alias would buy).
sed -e "s@^Agentconfig	Configpath@Agentconfigx	Configpath@" "$TSV" > "$W/undeclared.tsv"
cmp -s "$TSV" "$W/undeclared.tsv" && fail "the tsv sed matched NOTHING (the mutant would be the original)"
grep -q '^Agentconfigx' "$W/undeclared.tsv" || fail "the tsv mutant does not rename the alias"
arm b0b-alias-undeclared 1 'alias-undeclared' --check-aliases --aliases "$W/undeclared.tsv" --policy-lexicon "$LEX"
# b0c: a DECLARED alias missing from the table -- the lexicon and the table
# have drifted; refused in that direction too (the closure is both ways).
grep -v "^Agentdata	" "$TSV" > "$W/missing.tsv"
cmp -s "$TSV" "$W/missing.tsv" && fail "the tsv grep matched NOTHING"
arm b0c-alias-table-missing 1 'alias-table-missing' --check-aliases --aliases "$W/missing.tsv" --policy-lexicon "$LEX"
# b0d/b0e: the flag and the pattern are validated, not trusted.
sed -e "s@^Agentconfig	Configpath	yes@Agentconfig	Configpath	maybe@" "$TSV" > "$W/badflag.tsv"
cmp -s "$TSV" "$W/badflag.tsv" && fail "the flag sed matched NOTHING"
arm b0d-alias-protected-flag 1 'alias-protected-flag' --check-aliases --aliases "$W/badflag.tsv" --policy-lexicon "$LEX"
sed -e "s@^Agentconfig	Configpath	yes	/@Agentconfig	Configpath	yes	fx/@g" "$TSV" > "$W/badpat.tsv"
cmp -s "$TSV" "$W/badpat.tsv" && fail "the pattern sed matched NOTHING"
arm b0e-alias-bad-pattern 1 'alias-bad-pattern' --check-aliases --aliases "$W/badpat.tsv" --policy-lexicon "$LEX"
# b0f: THE SEAM, spelled: an underscored alias can never be a proper noun, so
# it can never reach a rule -- the checker refuses it at pin time.
sed -e "s@^Agentconfig@Agent_config@" "$TSV" > "$W/underscore.tsv"
cmp -s "$TSV" "$W/underscore.tsv" && fail "the underscore sed matched NOTHING"
arm b0f-alias-seam-spelling 1 'alias-undeclared' --check-aliases --aliases "$W/underscore.tsv" --policy-lexicon "$LEX"
# b0g: THE PATTERN GRAMMAR is enforced, not just stated: a trailing single
# '*' is the half-coverage shape an operator plausibly writes for "everything
# in here" — it would cover the children and NEVER the node (fnmatch's '*'
# spans '/').  Refused by name; the only subtree spelling is '<path>/**'.
sed -e "s@^Agentdata	Datadir	no	/fx/disk/agent-data\$@Agentdata	Datadir	no	/fx/disk/agent-data/*@" "$TSV" > "$W/ambig.tsv"
cmp -s "$TSV" "$W/ambig.tsv" && fail "the ambiguous-pattern sed matched NOTHING"
grep -q '/fx/disk/agent-data/\*$' "$W/ambig.tsv" || fail "the ambiguous mutant does not carry the trailing single star"
arm b0g-alias-ambiguous-pattern 1 'alias-ambiguous-pattern' --check-aliases --aliases "$W/ambig.tsv" --policy-lexicon "$LEX"
# b0h (S3): the AUTHORITY table is validated with its own two-form grammar
# (exact host / '*.suffix'), the argclass sort, and the protected flag.
arm b0h-hosts-ok 0 'host table OK' --check-hosts --hosts "$HOSTS" --policy-lexicon "$LEX"
sed -e "s@^example.com	Blockedhost@example.com	Blockedhostx@" "$HOSTS" > "$W/foreignhost.tsv"
cmp -s "$HOSTS" "$W/foreignhost.tsv" && fail "the hosts sed matched NOTHING"
arm b0i-host-foreign-sort 1 'host-foreign-sort' --check-hosts --hosts "$W/foreignhost.tsv" --policy-lexicon "$LEX"
sed -e "s@^example.com@*example.com@" "$HOSTS" > "$W/ambighost.tsv"
cmp -s "$HOSTS" "$W/ambighost.tsv" && fail "the hosts ambiguous sed matched NOTHING"
arm b0j-host-ambiguous-pattern 1 'host-ambiguous-pattern' --check-hosts --hosts "$W/ambighost.tsv" --policy-lexicon "$LEX"

echo "test_ops_policy: -- B1 the pin: determinism, artifact, shas --"
python3 "$EVAL" --compile-policy --policy-le "$POLICY" --policy-lexicon "$LEX" >"$W/policy.1" 2>"$W/policy.err" \
    || fail "compiling the ops policy failed: $(cat "$W/policy.err")"
python3 "$EVAL" --compile-policy --policy-le "$POLICY" --policy-lexicon "$LEX" >"$W/policy.2" 2>>"$W/policy.err" \
    || fail "the second ops policy compile failed: $(cat "$W/policy.err")"
cmp -s "$W/policy.1" "$W/policy.2" || fail "two ops policy compiles are NOT byte-identical (policy-pin determinism)"
grep -c '^denied(' "$W/policy.1" > "$W/headcount"
[ "$(cat "$W/headcount")" = 3 ] || fail "the ops policy artifact does not conclude exactly three denied rules ($(cat "$W/headcount"))"
cmp -s "$W/policy.1" "$ART" || fail "policy/ops/ops-policy.dl is NOT the artifact a fresh compile produces -- regenerate it with 'make ops-policy-artifact' and update policy/ops/PINS in the same commit"
for pair in 'ops-policy.dl' 'ops-lexicon.ini' 'ops-aliases.tsv' 'ops-hosts.tsv'; do
    case $pair in
        ops-policy.dl) sha_file=$(sha256sum "$W/policy.1" | cut -d' ' -f1) ;;
        ops-lexicon.ini) sha_file=$(sha256sum "$LEX" | cut -d' ' -f1) ;;
        ops-aliases.tsv) sha_file=$(sha256sum "$TSV" | cut -d' ' -f1) ;;
        ops-hosts.tsv) sha_file=$(sha256sum "$HOSTS" | cut -d' ' -f1) ;;
    esac
    sha_pin=$(grep "^$pair" "$PINS" | cut -f2)
    [ "$sha_file" = "$sha_pin" ] || fail "$pair: the pinned sha is $sha_pin, the file hashes to $sha_file -- the pin and the artifact have drifted"
done
echo "test_ops_policy: OK b1-policy-pin (two compiles byte-identical; artifact, lexicon and alias table all match policy/ops/PINS)"

echo "test_ops_policy: -- B2 the policy lint (heads are denied ONLY; every body consumes a seat template) --"
arm b2b-policy-vacuous 1 'policy-vacuous' --compile-policy --policy-le "$FIX/policy-vacuous.le" --policy-lexicon "$LEX"
# ...and the refusal NAMES what it refused (a refusal that cannot name the
# offending rule is a weak instrument): the rule text itself must appear in
# the record, interpolated, not the literal placeholder.
grep -qF 'denied(W1, P1) :- denied(W1, P4), denied(W2, P1)' "$W/b2b-policy-vacuous.txt" || \
    fail "b2b: the policy-vacuous refusal does not NAME the offending rule ($(grep -m1 reason "$W/b2b-policy-vacuous.txt" || cat "$W/b2b-policy-vacuous.txt"))"
grep -qF '{line!r}' "$W/b2b-policy-vacuous.txt" && \
    fail "b2b: the refusal printed the LITERAL placeholder {line!r} -- the offending rule is unnamed"
arm b2c-policy-foreign-head 1 'policy-foreign-head' --compile-policy --policy-le "$FIX/policy-foreign-head.le" --policy-lexicon "$LEX"

echo "test_ops_policy: -- B3 the two-author boundary: each side refuses the other's predicate --"
arm b3a-ops-lexicon-refuses-justified 1 'sentence-foreign-predicate' \
    --compile-sentence --policy-lexicon "$LEX" --sentence "$FIX/ops-sentence-justified.le"
arm b3b-claims-lexicon-refuses-denied 1 'sentence-foreign-predicate' \
    --compile-sentence --policy-lexicon "$CLAIMS_LEX" --sentence "$FIX/claims-sentence-denied.le"
arm b3c-claims-policy-lexicon-refuses-denied 1 'sentence-foreign-predicate' \
    --compile-sentence --policy-lexicon "$CLAIMS_PLEX" --sentence "$FIX/claims-sentence-denied.le"
grep -q 'ontology extension (the declared predicate set is closed)' "$W/b3a-ops-lexicon-refuses-justified.txt" || \
    fail "b3a: the refusal must quote le's own gap name, not paraphrase it"
# THE BOUNDARY IS THE CLOSURE, shown: add the foreign predicate to a COPY of
# the lexicon and the same sentence compiles -- the refusal was the lexicon's,
# not the sentence's or the tool's.
sed -e 's@^<a verb V> has <a kind K> | kind | verb, kind$@<a verb V> has <a kind K> | kind | verb, kind\n<a verb V> is justified | justified | verb@' "$LEX" > "$W/ops-lexicon-justified.ini"
cmp -s "$LEX" "$W/ops-lexicon-justified.ini" && fail "the ops-lexicon sed matched NOTHING (the mutant would be the original)"
grep -q '| justified |' "$W/ops-lexicon-justified.ini" || fail "the ops-lexicon mutant does not declare justified"
arm b3d-mutant-ops-lexicon-compiles 0 '^justified(W1) :-' \
    --compile-sentence --policy-lexicon "$W/ops-lexicon-justified.ini" --sentence "$FIX/ops-sentence-justified.le"
sed -e 's@^<a claim C> is justified | justified | claim$@<a claim C> is justified | justified | claim\n<a claim C> is denied | denied | claim@' \
    -e 's@^origin = origin$@origin = origin\n\n[names]\nClaimA = claim@' "$CLAIMS_PLEX" > "$W/claims-plex-denied.ini"
cmp -s "$CLAIMS_PLEX" "$W/claims-plex-denied.ini" && fail "the claims-lexicon sed matched NOTHING (the mutant would be the original)"
grep -q '| denied |' "$W/claims-plex-denied.ini" || fail "the claims-lexicon mutant does not declare denied"
grep -q '^ClaimA = claim' "$W/claims-plex-denied.ini" || fail "the claims-lexicon mutant does not declare ClaimA"
arm b3e-mutant-claims-lexicon-compiles 0 '^denied(claima) :-' \
    --compile-sentence --policy-lexicon "$W/claims-plex-denied.ini" --sentence "$FIX/claims-sentence-denied.le"

echo "test_ops_policy: -- B4 deny-direction, through the engine, over the REAL pinned table --"
# b4a: floor ALLOWS (the path is in the compiled-in writable set) and the
# policy DENIES (the alias's class is protected): D1 fires.  This is the
# anti-dead-layer arm -- a policy that never denied here would be decoration.
deny_arm b4a-d1-protected-write "$FIX/deny-protected-ok.tsv" 1 '(fx_write, /fx/disk/agent-config.dhall)'
# b4b: same floor, UNprotected class, boot ok: ZERO rows.  Negative control
# for D1 -- and the DENY-ALL detector (an unconditional policy fires here).
deny_arm b4b-d1-negative "$FIX/deny-data-ok.tsv" 0
# b4c: THE CONDITIONAL a list cannot express.  Identical facts to b4b except
# the boot verdict row is ABSENT (the bootlog is unreadable): D2 must deny --
# the rule fails CLOSED, which is what deny-more-only demands.
deny_arm b4c-d2-boot-not-ok "$FIX/deny-data-noboot.tsv" 1 '(fx_write, /fx/disk/agent-data)'
# ...and the pair is honest: the two fact bodies differ by EXACTLY the boot
# row (comments stripped before the comparison).
grep -v '^#' "$FIX/deny-data-ok.tsv" > "$W/b4-ok.body"
grep -v '^#' "$FIX/deny-data-noboot.tsv" > "$W/b4-noboot.body"
diff "$W/b4-ok.body" "$W/b4-noboot.body" > "$W/b4-pair.diff"
[ "$(grep -c '^<' "$W/b4-pair.diff")" = 1 ] || fail "b4: expected exactly one differing line between deny-data-ok and deny-data-noboot"
grep '^<' "$W/b4-pair.diff" | grep -q '^< boot_verdict' || fail "b4: the differing line is not the boot verdict row ($(cat "$W/b4-pair.diff"))"
# b4e: D2's fail-closed vs a DIFFERENT verdict atom, not just an ABSENT one:
# the verdict reads `failed` (degraded boot) — still not `ok`, still denied.
# The negation is over the ground constant ok; WHICH other atom is present
# must be indifferent.  The reviewer's probe, pinned.
deny_arm b4e-d2-boot-other-verdict "$FIX/deny-data-bootfailed.tsv" 1 '(fx_write, /fx/disk/agent-data)'
# ...and the pair is honest: deny-data-ok and deny-data-bootfailed differ by
# EXACTLY the boot row's value, nothing else.
grep -v '^#' "$FIX/deny-data-ok.tsv" > "$W/b4e-ok.body"
grep -v '^#' "$FIX/deny-data-bootfailed.tsv" > "$W/b4e-failed.body"
diff "$W/b4e-ok.body" "$W/b4e-failed.body" > "$W/b4e-pair.diff"
[ "$(grep -c '^<' "$W/b4e-pair.diff")" = 1 ] && [ "$(grep -c '^>' "$W/b4e-pair.diff")" = 1 ] \
    || fail "b4e: expected exactly one differing line between deny-data-ok and deny-data-bootfailed ($(cat "$W/b4e-pair.diff"))"
grep -q '^< boot_verdict	ok$' "$W/b4e-pair.diff" && grep -q '^> boot_verdict	failed$' "$W/b4e-pair.diff" \
    || fail "b4e: the differing line is not the boot verdict's VALUE ($(cat "$W/b4e-pair.diff"))"
# b4d: the kind scope holds: a READ on the protected path is not denied.
deny_arm b4d-kind-scope "$FIX/read-protected-ok.tsv" 0
# b4f: S2 D3's deny-direction — a HOST TOOL touching a PROTECTED path is
# denied via the hosttool bridge (no kind(write) fact, so only D3 can fire).
deny_arm b4f-d3-hosttool-protected "$FIX/deny-hostcat-protected.tsv" 1 '(host_cat, /fx/disk/agent-config.dhall)'
# b4g: S2 D3's negative control — a host tool touching an UNprotected path is
# NOT denied (the class is not protected; the DENY-ALL detector for D3).
deny_arm b4g-d3-hosttool-negative "$FIX/deny-hostcat-data.tsv" 0

echo "test_ops_policy: -- B5 the vocabulary seam: the loud refusal and the silent allow-all --"
# b5a: LOUD.  An underscored runtime verb can never be a proper noun: lexicon
# load is refused by name before any rule is seen.
sed -e 's@^Write = kind$@Write = kind\nFx_write = verb@' "$LEX" > "$W/lexicon-loud.ini"
cmp -s "$LEX" "$W/lexicon-loud.ini" && fail "the loud-seam lexicon sed matched NOTHING"
grep -q '^Fx_write = verb' "$W/lexicon-loud.ini" || fail "the loud-seam mutant does not spell Fx_write"
arm b5a-seam-loud 1 'not a proper noun' \
    --compile-policy --policy-le "$FIX/naive-spelling.le" --policy-lexicon "$W/lexicon-loud.ini"
# b5b: SILENT.  `Fxwrite` IS letters-only: the mutant lexicon accepts it, the
# naive policy COMPILES AND LINTS CLEAN (the lint cannot see semantics), and
# the pinned-looking artifact matches NOTHING -- the allow-all the seam
# finding warns about, executed.  b4a on the honest artifact is the control.
sed -e 's@^Write = kind$@Write = kind\nFxwrite = verb@' "$LEX" > "$W/lexicon-naive.ini"
cmp -s "$LEX" "$W/lexicon-naive.ini" && fail "the naive-seam lexicon sed matched NOTHING"
grep -q '^Fxwrite = verb' "$W/lexicon-naive.ini" || fail "the naive-seam mutant does not declare Fxwrite"
python3 "$EVAL" --compile-policy --policy-le "$FIX/naive-spelling.le" --policy-lexicon "$W/lexicon-naive.ini" >"$W/naive.dl" 2>&1 \
    || fail "b5b: the naive policy did not even compile -- the silent direction needs a policy that pins cleanly"
grep -q 'touches(fxwrite, P1)' "$W/naive.dl" || fail "b5b: the naive dl does not spell the folded constant fxwrite"
python3 "$W/driver.py" --policy "$W/naive.dl" --aliases "$TSV" --facts "$FIX/deny-protected-ok.tsv" >"$W/b5b.txt" 2>&1
grep -q '^rows=0$' "$W/b5b.txt" || fail "b5b: the naive-spelling policy DID derive on the real facts -- the silent allow-all could not be executed, so the arm proves nothing"
grep -q '^rows=1$' "$W/b4a-d1-protected-write.txt" || fail "b5b: the honest control (b4a) must derive while the naive one does not"
echo "test_ops_policy: OK b5b-seam-silent-allow-all (the naive spelling compiles, lints, and derives ZERO rows where the honest policy derives one -- THE failure direction the seam finding is about)"
# b5c: the SAME silent direction through the ALIAS TABLE: a typo'd pattern,
# with the pin honestly re-taken (an operator's own consistent bad edit --
# the pin check cannot catch it), silently stops protecting: no class fact,
# no protected fact, D1 never fires.  The deny arms are the catch.
sed -e 's@^Agentconfig	Configpath	yes	/fx/disk/agent-config.dhall$@Agentconfig	Configpath	yes	/fx/disk/agent-config.dhal@' "$TSV" > "$W/typo.tsv"
cmp -s "$TSV" "$W/typo.tsv" && fail "the typo sed matched NOTHING"
grep -q 'agent-config.dhal$' "$W/typo.tsv" || fail "the typo mutant does not mistype the pattern"
python3 "$W/driver.py" --policy "$ART" --aliases "$W/typo.tsv" --facts "$FIX/deny-protected-ok.tsv" >"$W/b5c.txt" 2>&1
grep -q '^resolved	class-facts=0	protected-facts=0$' "$W/b5c.txt" || fail "b5c: the typo'd table still resolved -- the silent allow-all through the table could not be executed"
grep -q '^rows=0$' "$W/b5c.txt" || fail "b5c: D1 still derived over the mistyped table"
echo "test_ops_policy: OK b5c-seam-silent-via-alias-table (a re-pinned typo'd pattern resolves to NOTHING; the denial disappears silently -- caught by b4a's assertion, and S2's seat must refuse loudly here)"
# b5d/b5e: THE PATTERN GRAMMAR'S SUBTREE FORM (the S1 review's measurement:
# patterns are fnmatch GLOBS, EXACT, NEVER PREFIXES -- a bare directory row
# passes validation, re-pins cleanly, and then protects nothing but the
# node).  b5d shows the LOUD fix working end to end; b5e executes the
# residual silent shape the grammar cannot read out of an operator's head.
# b5d: the subtree spelling '<path>/**' is LEGAL at pin time (check-aliases
# accepts it and echoes coverage=subtree) and the resolve covers the node
# ITSELF and a grandchild three levels below: both denials derive.
sed -e 's@^Agentdata	Datadir	no	/fx/disk/agent-data$@Agentdata	Datadir	yes	/fx/disk/agent-data/**@' "$TSV" > "$W/subtree.tsv"
cmp -s "$TSV" "$W/subtree.tsv" && fail "the subtree sed matched NOTHING"
grep -q '/fx/disk/agent-data/\*\*$' "$W/subtree.tsv" || fail "the subtree mutant does not carry the /** form"
arm b5d-subtree-form-legal 0 'coverage=subtree' --check-aliases --aliases "$W/subtree.tsv" --policy-lexicon "$LEX"
python3 "$W/driver.py" --policy "$ART" --aliases "$W/subtree.tsv" --facts "$FIX/deny-data-sub-ok.tsv" >"$W/b5d.txt" 2>&1
grep -q '^resolved	class-facts=2	protected-facts=1$' "$W/b5d.txt" || fail "b5d: the subtree pattern did not cover BOTH the node and the grandchild ($(grep '^resolved' "$W/b5d.txt" || cat "$W/b5d.txt"))"
grep -q '^rows=2$' "$W/b5d.txt" || fail "b5d: the subtree denial did not derive for both paths ($(grep '^rows=' "$W/b5d.txt"))"
grep -q 'denied(fx_write, /fx/disk/agent-data)$' "$W/b5d.txt" || fail "b5d: the NODE itself is not denied under the /** form (the grandchild row must not masquerade as it)"
grep -qF 'denied(fx_write, /fx/disk/agent-data/sub/deep/file)' "$W/b5d.txt" || fail "b5d: the grandchild is not denied under the /** form"
echo "test_ops_policy: OK b5d-subtree-form (the stated /** spelling covers the node AND its descendants -- the S1 review's rows=0 becomes two derived denials)"
# b5e: THE REVIEWER'S MEASUREMENT, executed: a bare protected directory row
# -- the plausible 'protect the data dir' edit -- is EXACT under the stated
# grammar, so the grandchild is covered by NO row and NO denial derives for
# it.  Pinned as EXACT-ONLY (a prefix-matching 'helpful' fix would flip this
# arm): the loud refusal for a SERVED path no row covers is S2's obligation
# (see the BOUND lines), not something pin time can read out of intent.
sed -e 's@^Agentdata	Datadir	no	/fx/disk/agent-data$@Agentdata	Datadir	yes	/fx/disk/agent-data@' "$TSV" > "$W/baredir.tsv"
cmp -s "$TSV" "$W/baredir.tsv" && fail "the bare-dir sed matched NOTHING"
python3 "$W/driver.py" --policy "$ART" --aliases "$W/baredir.tsv" --facts "$FIX/deny-data-sub-ok.tsv" >"$W/b5e.txt" 2>&1
grep -q '^resolved	class-facts=1	protected-facts=1$' "$W/b5e.txt" || fail "b5e: the bare-dir row resolved MORE than the exact node -- exact-only semantics violated ($(grep '^resolved' "$W/b5e.txt"))"
grep -q '^rows=1$' "$W/b5e.txt" || fail "b5e: expected exactly the node denial under the bare-dir row ($(grep '^rows=' "$W/b5e.txt"))"
grep -q 'denied(fx_write, /fx/disk/agent-data)$' "$W/b5e.txt" || fail "b5e: the node itself must still be denied (the row is exact, not absent)"
grep -qF 'denied(fx_write, /fx/disk/agent-data/sub/deep/file)' "$W/b5e.txt" && fail "b5e: the grandchild was denied under a BARE directory row -- glob-less patterns are NOT prefixes; this arm pins exact-only"
echo "test_ops_policy: OK b5e-exact-never-prefix (a bare protected dir row denies the NODE only -- the grandchild is silently uncovered, exactly the S1 review's measurement; S2 must refuse a served path no row covers)"

echo "test_ops_policy: -- B6 each deny rule proved able to fail, per direction --"
# b6a: drop rule D1 (the kind(write)+protected line) -- the protected-write
# denial disappears (the ALLOW-ALL direction, blind on exactly the b4a
# fixture).  D2 and D3 survive.
sed -e '/kind(W1, write), class(P1, C1)/d' "$ART" > "$W/mutant-d1.dl"
cmp -s "$ART" "$W/mutant-d1.dl" && fail "the D1 sed matched NOTHING (the mutant would be the original)"
[ "$(grep -c '^denied(' "$W/mutant-d1.dl")" = 2 ] || fail "the D1 mutant must leave exactly TWO deny rules (D2 and D3)"
python3 "$W/driver.py" --policy "$W/mutant-d1.dl" --aliases "$TSV" --facts "$FIX/deny-protected-ok.tsv" >"$W/b6a.txt" 2>&1
grep -q '^rows=0$' "$W/b6a.txt" || fail "b6a: the D1-mutant still denied the protected write -- D1 is not what denies it"
echo "test_ops_policy: OK b6a-d1-mutant (D1 dropped -> the protected-write denial vanishes: the arm can fail in the allow-all direction)"
# b6c: drop rule D3 (the hosttool bridge) -- a HOST TOOL touching a protected
# path is no longer denied (D1 cannot see it: host tools carry no kind(write)
# fact).  The D3-specific direction of the SAME allow-all class.
sed -e '/hosttool(W1)/d' "$ART" > "$W/mutant-d3.dl"
cmp -s "$ART" "$W/mutant-d3.dl" && fail "the D3 sed matched NOTHING (the mutant would be the original)"
[ "$(grep -c '^denied(' "$W/mutant-d3.dl")" = 2 ] || fail "the D3 mutant must leave exactly TWO deny rules (D1 and D2)"
python3 "$W/driver.py" --policy "$W/mutant-d3.dl" --aliases "$TSV" --facts "$FIX/deny-hostcat-protected.tsv" >"$W/b6c.txt" 2>&1
grep -q '^rows=0$' "$W/b6c.txt" || fail "b6c: the D3-mutant still denied the host tool's protected path -- D3 is not what denies it"
echo "test_ops_policy: OK b6c-d3-mutant (D3 dropped -> the host-tool protected-path denial vanishes: the host-tool direction can fail in the allow-all direction)"
# b6b: drop D2's boot condition -- D2 becomes an UNCONDITIONAL writable
# denial: the DENY-ALL direction, blind on exactly the b4b fixture.
sed -e 's@, !boot_verdict(ok)@@' "$ART" > "$W/mutant-d2.dl"
cmp -s "$ART" "$W/mutant-d2.dl" && fail "the D2 sed matched NOTHING (the mutant would be the original)"
grep -q 'writable(P1)\.' "$W/mutant-d2.dl" || fail "the D2 mutant does not end at the writable atom"
grep -q 'boot_verdict' "$W/mutant-d2.dl" && fail "the D2 mutant still mentions the boot verdict"
python3 "$W/driver.py" --policy "$W/mutant-d2.dl" --aliases "$TSV" --facts "$FIX/deny-data-ok.tsv" >"$W/b6b.txt" 2>&1
grep -q '^rows=1$' "$W/b6b.txt" || fail "b6b: the boot-condition-dropped mutant did NOT deny the ok-boot write -- the conditional is not what gates D2"
echo "test_ops_policy: OK b6b-d2-mutant (the boot condition dropped -> the ok-boot write is denied: the arm can fail in the deny-all direction)"

echo "test_ops_policy: BOUND -- S1 compiles, lints, pins and VALIDATES only; the enforcement seat at the fx-verbs server's commit sites is slice S2, and nothing here changes any server or floor behavior."
echo "test_ops_policy: BOUND -- deny-more-only: the policy vocabulary has NO allow predicate; every head is 'denied'; D2 fails CLOSED (an absent/unreadable boot verdict satisfies the denial)."
echo "test_ops_policy: BOUND -- the seam is designed around, not assumed: spelled runtime symbols are refused LOUDLY at lexicon load (b5a), the naive letters-only spelling is shown to pin cleanly and silently allow (b5b), and a re-pinned typo'd alias pattern does the same through the table (b5c) -- each caught only by the deny-direction arms, which is why those anchor to the REAL pinned table."
echo "test_ops_policy: BOUND -- the driver resolves alias patterns against the fact set's paths; S2's seat must do the same at startup and REFUSE LOUDLY when a protected alias matches nothing (b5c is the defect it prevents), and must implement the SAME two-form pattern grammar the checker enforces (exact, or '<path>/**' subtree -- b5d is the semantics, b0g the refusals)."
echo "test_ops_policy: BOUND -- the uncovered-path direction (S1 review, nice-to-have (i)): a SERVED writable path covered by NO row is silently unclassified (b5e executes it: the grandchild under a bare-dir row).  Deny-more-only makes this untightened-not-loosened, but S2's startup obligation is BOTH directions: a protected alias matching nothing AND a served path no row covers -- refuse loudly, never silently unguarded."
echo "test_ops_policy: BOUND -- the folding contract (S1 review, nice-to-have (iii), stated in ops-lexicon.ini): the seat injects FOLDED symbols (Write -> write, Ok -> ok); an unfolded surface would silently non-match (the allow-all direction).  S2 machine-checks it: startup asserts every verb-table row acquired its kind fact, per call that the canon path acquired its class fact; relation-level shape mismatches are already loud (dlb refuses an unknown predicate by name)."
echo "test_ops_policy: BOUND -- the asymmetric control: these arms are NEW (nothing pre-change to mutate); the claim unit's gates (make test-claim-policy, make test-claim) staying UNTOUCHED and green is the proof this slice did not disturb the shared machinery."
echo "test_ops_policy: PASS -- the operator policy is closed, pinned, deny-more-only, and every rule in it is proved able to FAIL in a named direction."
exit 0
