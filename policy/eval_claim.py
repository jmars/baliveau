#!/usr/bin/env python3
"""policy/eval_claim.py -- THE FREE-LE CLAIM EVALUATOR (the host-side seat).

WHAT IT DECIDES.  Given a claim (the /etc/fx-claim.tsv row + the
/etc/fx-claim.le argument), the AGENT-FACING closed lexicon, the PINNED
frozen policy and the store facts as of the claim's from_version, it answers
exactly one question: does `justified(<claim>)` DERIVE?  A verdict of
`derives` has exactly one meaning -- a row came out of the least fixpoint of
(pinned policy + the agent's argument) over (the store facts + the claim
row's bindings).  Everything else is a NAMED refusal, and every refusal
names the check that produced it.

THE EVALUATION PATH, in order, each step a refusal by name:

  1. PIN.        If --pins is given, sha256 of the agent lexicon and of the
                 compiled policy must equal the pinned values, else
                 `stale-lexicon` / `stale-policy`.  A mutated lexicon is
                 REFUSED, never silently widened.  With no --pins the record
                 SAYS SO (`pin lexicon=none policy=none`) -- an unpinned run
                 is stated, never silent.
  2. COMPILE.    The claim is compiled against the agent lexicon by the
                 EXISTING `le` compiler, consumed as a dependency.  THE CLOSED
                 LEXICON IS THE BOUNDARY: the agent lexicon declares no
                 `justified` and no [actions], so the agent's sentence cannot
                 name the judgment predicate (nor be reactive), and a sentence
                 naming an undeclared predicate is le's own loud
                 GAP_CLOSED_LEXICON (le/lower.py:78) -- that is the hostile
                 claim's refusal (`hostile-compile`).
  3. HEAD CHECK. The compiled claim's rule HEADS must be inside the
                 agent-conclusion subset (contention + the intermediate pool).
                 The STORE TEMPLATES are body-only for the agent: an agent
                 rule that concludes one is `head-forgery`.  le does not know
                 which predicates are store predicates, so this check is the
                 evaluator's.
  4. PREMISES.   Every FACT the claim asserts is looked up in the store-only
                 engine (the store facts as of from_version, no claim facts
                 added yet).  Absent -> `premise-false`: the claim's premises
                 are checked against the store, never taken on its word.

So the boundary IN THE EVALUATION PATH is the closure + the head check + the
premise check.  The lexicon RELEASE check -- that the agent lexicon declares
exactly the agent-conclusion subset and never `justified` -- is a SEPARATE
mode (`--lint-lexicon`), run where a lexicon is authored/pinned, NOT a step
here: with it inline, a mutant lexicon could not reach the compiler, and the
gate's mutant arm -- which exists to prove the boundary IS the closure --
would be claiming a refusal from the wrong check.

Then the query: `justified` over the policy's pinned rule TEXT plus the
claim's rules, with the row bindings (claim_from / claim_config) and the
landed configuration injected as facts.  Zero rows -> `justified-not-derived`
-- which IS the vacuity verdict: an argument that never reaches the judgment
rule derives nothing, and nothing is what refuses it.  No vacuity police
exists or is needed.

FROZEN TABLES.  RELATIONS below carries the store's real schemas (MEASURED:
fxstore/zig/src/provenance.zig:363-393) -- `install`'s third column is
raw-u32 mode, the rest are sym -- and is what reads an `fxstore facts` dump
(fxstore/zig/src/main.zig:191-195: one fact per line, TAB-separated, symbols
resolved to strings, raw u32 columns in decimal).  STORE_TEMPLATES and
AGENT_CONCLUSIONS are the boundary tables; they, not comments, are what the
checks read, and the gate mutates them to prove each check can fail.
STORE_TEMPLATES is also what TYPES the facts dump: the dump may name a store
template and nothing else, so neither a row binding nor the judgment predicate
can reach the engine from outside this file -- the verdict then names only the
claim the rows carry.

MODES.
  (default)          evaluate a claim; exit 0 = derives, 1 = refused by name,
                     2 = tool error (a bad invocation or an unreadable input
                     -- never a silent does-not-derive).
  --lint-lexicon F   assert the agent lexicon's boundary (the lexicon RELEASE
                     check above; not part of the evaluation path) and exit.
  --compile-policy   compile --policy-le with --policy-lexicon, LINT the
                     result (every head is `justified`; every judgment rule's
                     body mentions at least one store template --
                     `policy-vacuous` / `policy-foreign-head` otherwise), and
                     print the pinned rule text on stdout.  This is the ONLY
                     path that produces policy/claims-policy.dl, so the pin
                     and the lint cannot drift apart.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import shutil
import sys
import tempfile

# ── the frozen tables ─────────────────────────────────────────────────────
# relation -> (arity, column kinds).  `sym` columns are interned strings,
# `raw` columns are plain u32 (the store prints them in decimal).
RELATIONS = {
    # the store's own relations, as the store declares them
    "generation_config": (3, ("sym", "sym", "sym")),
    "install": (4, ("sym", "sym", "raw", "sym")),
    "provides": (2, ("sym", "sym")),
    # injected by THIS evaluator from the claim row / the landed configuration
    "claim_from": (2, ("sym", "sym")),
    "claim_config": (2, ("sym", "sym")),
    "landed_config": (1, ("sym",)),
    # the judgment predicate (host-only; declared so the goal can be queried)
    "justified": (1, ("sym",)),
}

# A store template: the agent may consume these in a BODY and may never
# manufacture them (the head check below is what enforces it).
STORE_TEMPLATES = frozenset({"generation_config", "install", "provides"})

# The agent's conclusion subset: the contention predicate plus the
# intermediate pool.  The agent lexicon must declare exactly these (checked by
# --lint-lexicon), so the table and the lexicon cannot drift.
AGENT_CONCLUSIONS = frozenset({"contention", "grounded", "noted"})

JUDGMENT = "justified"

# le's own gap name (le/lower.py:78), quoted back in the refusal so the
# refusal names the compiler gap rather than paraphrasing it.
GAP_CLOSED_LEXICON = "ontology extension (the declared predicate set is closed)"

_ATOM_HEAD = re.compile(r"([a-z][A-Za-z0-9_]*)\s*\(")
_FACT = re.compile(r"\s*([a-z][A-Za-z0-9_]*)\s*\((.*)\)\s*\.\s*\Z", re.S)
_SYMBOL = re.compile(r"[a-z][a-z0-9_]*\Z")


def _tool_error(detail: str, code: int = 2) -> "NoReturn":  # noqa: F821
    print(f"fx-claim: TOOL ERROR: {detail}", file=sys.stderr)
    sys.exit(code)


def _refuse(name: str, detail: str, extra=()) -> "NoReturn":  # noqa: F821
    """A named refusal: exit 1, and the record says WHICH check refused."""
    print(f"# fx-claim: REFUSED -- {name}")
    print(f"verdict\trefused\t{name}")
    print(f"reason\t{detail.replace(chr(9), ' ')}")
    for row in extra:
        print(row)
    sys.exit(1)


def _sha256(path: str) -> str:
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


# ── the engine (dlb, le.driver's blessed binding path) ────────────────────
def _load_dlb():
    try:
        import dlb  # noqa: F401
    except Exception as first:
        path = os.environ.get("DLB_PATH")
        if not path:
            _tool_error(
                "the datalog engine binding is not importable and DLB_PATH is "
                f"unset ({first}); set DLB_PATH to the directory holding the "
                "'dlb' package (the sibling datalog-dafsa's python/)"
            )
        sys.path.insert(0, path)
        try:
            import dlb  # noqa: F811
        except Exception as second:  # pragma: no cover - environment dependent
            _tool_error(f"import dlb along DLB_PATH={path} failed ({second})")
    return dlb


class _Engine:
    """A scratch dlb store: facts in, least-fixpoint queries out."""

    def __init__(self, dlb, relations: dict):
        self.dlb = dlb
        self.dir = tempfile.mkdtemp(prefix="fx-claim-eval-")
        try:
            self.db = dlb.Db.open(self.dir)
        except Exception as exc:
            shutil.rmtree(self.dir, ignore_errors=True)
            _tool_error(f"cannot open the scratch store at {self.dir}: {exc}")
        for name, arity in relations.items():
            self.db.declare_relation(name, arity)
        self.relations = relations

    def close(self):
        try:
            self.db.close()
        finally:
            shutil.rmtree(self.dir, ignore_errors=True)

    def intern(self, s: str) -> int:
        return self.db.intern(s)

    def sym_of(self, sym: int):
        """The symbol an interned id stands for (None if it is not one), so a
        refusal can NAME what it found instead of printing a raw u32."""
        return self.db.sym_of(sym)

    def columns(self, relation: str, fields) -> tuple:
        kinds = RELATIONS[relation][1]
        if len(fields) != len(kinds):
            _tool_error(
                f"{relation}: {len(fields)} column(s) in the dump, the frozen "
                f"schema declares {len(kinds)}"
            )
        cols = []
        for kind, field in zip(kinds, fields):
            field = field.strip()
            if kind == "raw":
                try:
                    cols.append(int(field))
                except ValueError:
                    _tool_error(
                        f"{relation}: column '{field}' is raw-u32 in the "
                        "store's schema but is not an integer"
                    )
            else:
                cols.append(self.intern(_unquote(field)))
        return tuple(cols)

    def add(self, relation: str, cols) -> None:
        try:
            self.db.add_fact(relation, cols)
        except Exception as exc:
            _tool_error(f"add_fact {relation}{cols} failed: {exc}")

    def lookup(self, relation: str, cols) -> bool:
        try:
            return bool(self.db.lookup(relation, cols))
        except Exception as exc:
            _tool_error(f"lookup {relation}{cols} failed: {exc}")

    def prefix(self, relation: str, leading) -> list:
        """The rows whose first columns are `leading` (a partial lookup: the
        policy existentially binds the columns past the spine's pair)."""
        try:
            return list(self.db.iter(relation, tuple(leading)))
        except Exception as exc:
            _tool_error(f"iter {relation}{leading} failed: {exc}")

    def query(self, rules_text: str, goal: str) -> list:
        try:
            return list(self.db.query_rules_ro(rules_text, goal))
        except Exception as exc:
            _tool_error(f"query_rules_ro({goal}) failed: {exc}")


def _unquote(token: str) -> str:
    token = token.strip()
    if len(token) >= 2 and token[0] == '"' and token[-1] == '"':
        return token[1:-1].replace('\\"', '"').replace("\\\\", "\\")
    return token


def _col_of_token(engine: _Engine, token: str) -> int:
    """One dl fact argument -> a u32 column.  A bare integer is a raw column
    (the store prints raw u32 columns in decimal); everything else is a
    symbol, interned.  le never emits a bare all-digit token that is meant as
    a symbol literal, so the split is exact for the compiled streams."""
    token = token.strip()
    if token.isdigit():
        return int(token)
    return engine.intern(_unquote(token))


def _split_fact(text: str):
    match = _FACT.match(text)
    if not match:
        _tool_error(f"not a dl fact: {text!r}")
    pred, args = match.group(1), match.group(2).strip()
    return pred, [a.strip() for a in args.split(",") if a.strip()]


# ── inputs ────────────────────────────────────────────────────────────────
def _read(path: str, what: str) -> str:
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except OSError as exc:
        _tool_error(f"cannot read the {what} at {path}: {exc}")


def _load_pins(path: str) -> dict:
    pins = {}
    for lineno, line in enumerate(_read(path, "pin file").splitlines(), 1):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        fields = line.split("\t")
        if len(fields) != 2 or not fields[0] or not fields[1]:
            _tool_error(f"{path}:{lineno}: the pin file is 'name<TAB>sha256'")
        pins[fields[0].strip()] = fields[1].strip()
    return pins


def _read_claim_row(path: str):
    """The claim row: claim<TAB>config-diff<TAB>from_version<TAB>S_from."""
    rows = []
    for lineno, line in enumerate(_read(path, "claim row").splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        rows.append((lineno, line.split("\t")))
    if len(rows) != 1:
        _tool_error(f"{path}: expected exactly one claim row, found {len(rows)}")
    lineno, fields = rows[0]
    if len(fields) != 4 or not all(f.strip() for f in fields):
        _refuse(
            "malformed-claim",
            f"{path}:{lineno}: a claim row is exactly four TAB-separated "
            "fields (claim, config-diff, from_version, S_from); got "
            f"{len(fields)} field(s): {line!r}",
        )
    return tuple(f.strip() for f in fields)


def _fold_claim_id(lexicon, surface: str, where: str) -> str:
    """The row's claim id -> the dl symbol the compiler folds to.

    The row carries the claim's SURFACE name; le's fold is the lowercased
    surface when that is a legal dl bare symbol (le/binding.py:144-159), and
    the name must be declared in the lexicon's [names] with sort 'claim' --
    an undeclared id is a loud refusal, never a silent does-not-derive."""
    folded = surface.lower()
    if not _SYMBOL.match(folded):
        _refuse(
            "malformed-claim",
            f"{where}: the claim id '{surface}' does not fold to a dl symbol "
            "(le/binding.py:144-159)",
        )
    for name, sort in lexicon.names.items():
        if name.lower() == folded:
            if sort != "claim":
                _refuse(
                    "undeclared-claim-id",
                    f"{where}: '{surface}' is declared in [names] with sort "
                    f"'{sort}', not 'claim'",
                )
            return folded
    _refuse(
        "undeclared-claim-id",
        f"{where}: the claim id '{surface}' (dl symbol '{folded}') is not "
        "declared in the agent lexicon's [names] section -- a claim id the "
        "vocabulary cannot name cannot be argued about",
    )


# ── the boundary: the agent lexicon ───────────────────────────────────────
def _lint_lexicon(lexicon, path: str) -> None:
    declared = {}
    for tpl in lexicon.templates:
        declared[tpl.pred] = "predicates"
    for tpl in lexicon.actions:
        declared[tpl.pred] = "actions"
    for tpl in lexicon.meta:
        declared[tpl.pred] = "meta"
    if JUDGMENT in declared:
        _refuse(
            "boundary-reopened",
            f"{path}: the agent lexicon declares '{JUDGMENT}' in "
            f"[{declared[JUDGMENT]}] -- the judgment predicate is the host "
            "policy's alone; a lexicon release that declares it reopens the "
            "soundness boundary",
        )
    if lexicon.actions:
        _refuse(
            "boundary-reopened",
            f"{path}: the agent lexicon declares an [actions] section "
            f"({', '.join(sorted(lexicon.action_preds))}) -- a claim is "
            "declarative; the reactive form is the driver's, not the "
            "evaluator's",
        )
    missing = sorted(AGENT_CONCLUSIONS - set(declared))
    if missing:
        _refuse(
            "boundary-reopened",
            f"{path}: the agent-conclusion subset {sorted(AGENT_CONCLUSIONS)} "
            f"is not declared here; missing {missing} -- the evaluator's "
            "frozen table and the lexicon have drifted apart",
        )


# ── the policy ────────────────────────────────────────────────────────────
def _lint_policy(rules_text: str, where: str) -> None:
    """Every head is `justified`, and every judgment rule's body consumes at
    least one store template.  A judgment rule with no store-template atom in
    its body judges on the claim's own say-so (the spine is gone) and is
    refused at pin time -- the vacuity guard is a property of the POLICY."""
    rules = [line for line in rules_text.splitlines() if line.strip()]
    if not rules:
        _refuse("policy-vacuous", f"{where}: the policy concludes nothing")
    for line in rules:
        head = _ATOM_HEAD.match(line)
        if not head:
            _refuse("policy-foreign-head", f"{where}: not a rule: {line!r}")
        pred = head.group(1)
        if pred != JUDGMENT:
            _refuse(
                "policy-foreign-head",
                f"{where}: the policy concludes '{pred}'; every head of the "
                f"frozen policy is '{JUDGMENT}'",
            )
        body = line.split(":-", 1)[1] if ":-" in line else ""
        if not (STORE_TEMPLATES & set(_ATOM_HEAD.findall(body))):
            _refuse(
                "policy-vacuous",
                f"{where}: the judgment rule's body consumes no store "
                f"template (one of {sorted(STORE_TEMPLATES)}) -- it judges on "
                "the claim's own say-so with no store spine: {line!r}",
            )


def _compile_policy(args, emit=True) -> str:
    lexicon = _load_lexicon(args.policy_lexicon)
    text = _read(args.policy_le, "policy")
    le = _load_le()
    try:
        result = le.compile_text(text, lexicon)
    except le.CompileError as exc:
        _refuse("policy-compile", f"{args.policy_le}: {exc}")
    _lint_policy(result.rules, args.policy_le)
    if emit:
        sys.stdout.write(result.rules)
    return result.rules


def _load_lexicon(path: str):
    le = _load_le()
    try:
        return le.Lexicon.load(path)
    except le.CompileError as exc:
        _refuse("lexicon", f"{path}: {exc}")
    except OSError as exc:
        _tool_error(f"cannot read the lexicon at {path}: {exc}")


_LE_MODULE = None


def _load_le():
    """`le`, consumed as a DEPENDENCY from its own checkout -- never forked."""
    global _LE_MODULE
    if _LE_MODULE is not None:
        return _LE_MODULE
    root = os.environ.get("LE_DIR")
    if root:
        sys.path.insert(0, root)
    try:
        import le
    except Exception as exc:
        _tool_error(
            f"the le package is not importable ({exc}); put its checkout on "
            "PYTHONPATH or set LE_DIR (e.g. $HOME/logical-english)"
        )
    _LE_MODULE = le
    return le


# ── the evaluation ────────────────────────────────────────────────────────
def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        prog="eval_claim",
        description="Evaluate a pre-registered claim: does justified derive?",
    )
    parser.add_argument("--claim", help="the claim row (TSV)")
    parser.add_argument("--le", dest="claim_le", help="the claim argument (LE)")
    parser.add_argument("--lexicon", help="the AGENT-FACING closed lexicon")
    parser.add_argument("--policy", help="the compiled, pinned policy rule text")
    parser.add_argument("--facts", action="append", default=[],
                        help="store facts as of from_version (an `fxstore "
                             "facts` dump: relation<TAB>col...); repeatable")
    parser.add_argument("--landed-config", help="the configuration now landed")
    parser.add_argument("--pins", help="the pin file (name<TAB>sha256)")
    parser.add_argument("--lint-lexicon", metavar="PATH",
                        help="assert the agent lexicon's boundary and exit")
    parser.add_argument("--compile-policy", action="store_true",
                        help="compile + lint the policy and print it")
    parser.add_argument("--policy-le")
    parser.add_argument("--policy-lexicon")
    args = parser.parse_args(argv)

    if args.lint_lexicon:
        lexicon = _load_lexicon(args.lint_lexicon)
        _lint_lexicon(lexicon, args.lint_lexicon)
        print(f"# fx-claim: lexicon OK -- {args.lint_lexicon}")
        print("boundary\tjudgment-in-agent-lexicon=absent\tactions=none\t"
              f"agent-conclusions={','.join(sorted(AGENT_CONCLUSIONS))}")
        print(f"lexicon\t{args.lint_lexicon}\tsha256={_sha256(args.lint_lexicon)}")
        return 0

    if args.compile_policy:
        for needed, flag in ((args.policy_le, "--policy-le"),
                             (args.policy_lexicon, "--policy-lexicon")):
            if not needed:
                _tool_error(f"--compile-policy needs {flag}")
        _compile_policy(args)
        return 0

    for needed, flag in ((args.claim, "--claim"), (args.claim_le, "--le"),
                         (args.lexicon, "--lexicon"), (args.policy, "--policy")):
        if not needed:
            _tool_error(f"evaluating a claim needs {flag}")
    if not args.facts:
        _tool_error("evaluating a claim needs at least one --facts dump")
    if args.landed_config is None:
        _tool_error("evaluating a claim needs --landed-config")

    le = _load_le()
    dlb = _load_dlb()

    # ── step 1: the pin (an unpinned run is STATED, never silent) ──────
    pins = _load_pins(args.pins) if args.pins else {}
    lexicon_sha = _sha256(args.lexicon) if pins else "none"
    policy_sha = _sha256(args.policy) if pins else "none"
    if pins:
        want_lexicon = pins.get("claims-lexicon.ini")
        want_policy = pins.get("claims-policy.dl")
        # A --pins file that names only ONE of the two is an INCOMPLETE pin:
        # the other file would go unverified while the record still showed a
        # sha, which is exactly the "verified" vs "merely stated" confusion the
        # pin exists to prevent.  Refuse rather than half-pin.
        if not want_lexicon or not want_policy:
            _refuse("pin-incomplete",
                    f"{args.pins}: a pin file must name BOTH "
                    "'claims-lexicon.ini' and 'claims-policy.dl'; it names "
                    f"{sorted(pins)} -- the missing entry's file would go "
                    "unverified")
        if lexicon_sha != want_lexicon:
            _refuse("stale-lexicon",
                    f"{args.lexicon}: sha256 {lexicon_sha} is not the pinned "
                    f"{want_lexicon} in {args.pins} -- a mutated agent lexicon "
                    "is refused, never silently widened")
        if policy_sha != want_policy:
            _refuse("stale-policy",
                    f"{args.policy}: sha256 {policy_sha} is not the pinned "
                    f"{want_policy} in {args.pins} -- re-judgment happens under "
                    "a NEW policy artifact, never a rewritten one")

    # ── the agent lexicon (its closure IS the boundary) ────────────────
    # The boundary is enforced by the CLOSED LEXICON itself (le refuses an
    # undeclared predicate by name) and by the head check below.  The lexicon
    # release check (--lint-lexicon) is a SEPARATE mode, run where a lexicon
    # is authored/pinned, not on every evaluation: with it inline, a mutant
    # lexicon could not even reach the compiler, and the gate's mutant arm --
    # which exists to prove the boundary IS the closure -- would be claiming
    # a refusal from the wrong check.
    lexicon = _load_lexicon(args.lexicon)

    # ── step 2: compile the claim (le, as a dependency) ────────────────
    row = _read_claim_row(args.claim)
    claim_surface, config_diff, from_version, s_from = row
    claim_sym = _fold_claim_id(lexicon, claim_surface, args.claim)
    claim_text = _read(args.claim_le, "claim argument")
    try:
        result = le.compile_text(claim_text, lexicon)
    except le.CompileError as exc:
        if exc.gap == GAP_CLOSED_LEXICON:
            _refuse(
                "hostile-compile",
                f"{args.claim_le}: the agent lexicon is closed and does not "
                f"declare the sentence's predicate -- le refuses by name "
                f"[{GAP_CLOSED_LEXICON}]: {exc}",
                extra=(f"lexicon\t{args.lexicon}\tsha256={lexicon_sha}",),
            )
        _refuse("compile-refused", f"{args.claim_le}: {exc}")

    # ── step 3: the head check (store templates are body-only) ─────────
    for line in [l for l in result.rules.splitlines() if l.strip()]:
        head = _ATOM_HEAD.match(line)
        if not head:
            _tool_error(f"the compiled claim has a rule with no head: {line!r}")
        pred = head.group(1)
        if pred not in AGENT_CONCLUSIONS:
            _refuse(
                "head-forgery",
                f"{args.claim_le}: the claim concludes '{pred}', which is not "
                f"in the agent-conclusion subset {sorted(AGENT_CONCLUSIONS)}; "
                f"the store templates {sorted(STORE_TEMPLATES)} are body-only "
                "for the agent -- an agent rule may consume the spine, never "
                "manufacture it",
            )

    # ── the engine: facts in, least fixpoint out ───────────────────────
    relations = {name: arity for name, (arity, _) in RELATIONS.items()}
    for tpl in lexicon.templates:
        relations.setdefault(tpl.pred, len(tpl.sorts))
    engine = _Engine(dlb, relations)
    try:
        stored = 0
        for dump in args.facts:
            for lineno, line in enumerate(
                    _read(dump, "facts dump").splitlines(), 1):
                if not line.strip() or line.lstrip().startswith("#"):
                    continue
                fields = line.split("\t")
                relation = fields[0].strip()
                # A facts dump carries STORE facts only.  RELATIONS is the
                # union of the store templates, the row bindings THIS evaluator
                # injects, and the judgment predicate itself; admitting any of
                # the latter would let the dump feed the goal -- a `justified`
                # row would make the verdict rest on a row the subject could
                # have asserted, through the evaluator's ONE trusted-facts
                # channel.  Type the channel to the store templates.
                if relation not in STORE_TEMPLATES:
                    _tool_error(
                        f"{dump}:{lineno}: the dump names the relation "
                        f"'{relation}', which is not a store template "
                        f"({sorted(STORE_TEMPLATES)}) -- a facts dump carries "
                        "store facts only; the row bindings and the judgment "
                        "predicate are this evaluator, never the dump"
                    )
                engine.add(relation, engine.columns(relation, fields[1:]))
                stored += 1
        if not stored:
            _tool_error(f"the facts dump(s) {args.facts} hold no facts")

        # ── step 4: premise verification, against the STORE ONLY ───────
        for fact in result.facts:
            pred, args_text = _split_fact(fact)
            if pred not in relations:
                _tool_error(f"the compiled claim asserts the unknown {pred}")
            cols = tuple(_col_of_token(engine, a) for a in args_text)
            if not engine.lookup(pred, cols):
                _refuse(
                    "premise-false",
                    f"{args.claim_le}: the asserted premise '{fact.strip()}' "
                    "does not derive from the store facts as of from_version "
                    f"'{from_version}'",
                    extra=(f"facts\tstore-rows={stored}",),
                )

        # the row's bindings: injected by the EVALUATOR, never by the claim
        claim_col = engine.intern(claim_sym)
        from_col = engine.intern(from_version)
        s_from_col = engine.intern(s_from)
        landed_col = engine.intern(args.landed_config)
        engine.add("claim_from", (claim_col, from_col))
        engine.add("claim_config", (claim_col, s_from_col))
        engine.add("landed_config", (landed_col,))

        # the two things a NON-derivation is made of, read directly so the
        # record names the cause instead of leaving it to be guessed
        spine = bool(engine.prefix("generation_config", (from_col, s_from_col)))
        guard = engine.lookup("landed_config", (s_from_col,))

        rules_text = _read(args.policy, "policy") + result.rules
        rows = engine.query(rules_text, JUDGMENT)
        # The verdict NAMES the claim it judged, so a row for any other symbol
        # would print a verdict the rows do not support.  dlb rows are tuples
        # of interned u32, so this compares interned ids, not strings.
        foreign = [r for r in rows if len(r) != 1 or r[0] != claim_col]
        if foreign:
            named = ", ".join(
                repr(engine.sym_of(r[0])) if len(r) == 1 else repr(r)
                for r in foreign
            )
            _tool_error(
                f"justified derived for symbols other than '{claim_sym}': "
                f"{named} -- the verdict names only the claim it judged"
            )
    finally:
        engine.close()

    print("# fx-claim: evaluated against the pinned policy + the agent's "
          "argument (free LE over the closed agent lexicon)")
    print(f"claim\t{claim_sym}\tfrom_version={from_version}\ts_from={s_from}"
          f"\tdiff={config_diff}")
    print("boundary\tjudgment-in-agent-lexicon=absent\t"
          f"agent-conclusions={','.join(sorted(AGENT_CONCLUSIONS))}\t"
          f"store-templates={','.join(sorted(STORE_TEMPLATES))}")
    print(f"pin\tlexicon={lexicon_sha}\tpolicy={policy_sha}")
    print(f"facts\tstore-rows={stored}")
    print(f"agent\tfacts={len(result.facts)}\trules={len(result.rule_lines)}")
    print(f"spine\tgeneration_config({from_version},{s_from},_)\t"
          f"{'PRESENT' if spine else 'ABSENT'}")
    print(f"guard\tlanded_config({s_from})\t{'PRESENT' if guard else 'ABSENT'}")
    if rows:
        print(f"verdict\tderives\tjustified({claim_sym})\trows={len(rows)}")
        return 0
    print("verdict\trefused\tjustified-not-derived")
    print("reason\tzero rows for 'justified' -- the claim's argument does not "
          "reach the frozen policy's judgment rule (a vacuous argument, or a "
          "spine/guard that does not hold as of the claim's from_version)")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
