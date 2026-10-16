#!/usr/bin/env python3
"""policy/calls/eval_calls.py -- THE FREE-LE CALLS EVALUATOR (the host-side
claim-author seat for the tool-call channel).

The THIN sibling of policy/eval_claim.py, re-targeted at tool calls: given a
call (the call's binding row + the agent's justification argument), the
AGENT-FACING closed lexicon, the PINNED frozen policy and the seat's injected
facts, it answers exactly one question: does `justified(<call>)` DERIVE?  A
verdict of `derives` has exactly one meaning — a row came out of the least
fixpoint of (pinned policy + the agent's argument) over (the seat's facts +
the call row's bindings).  Everything else is a NAMED refusal.

THE EVALUATION PATH, in order, each step a refusal by name (the eval_claim.py
shape, transplanted):

  1. PIN.        If --pins is given, sha256 of the agent lexicon and of the
                 compiled policy must equal the pinned values, else
                 `stale-lexicon` / `stale-policy`.
  2. COMPILE.    The justification is compiled against the agent lexicon by the
                 EXISTING `le` compiler.  THE CLOSED LEXICON IS THE BOUNDARY:
                 the agent lexicon declares no `justified` and no `denied`, so
                 the agent's sentence cannot name either — le's own loud
                 GAP_CLOSED_LEXICON (`hostile-compile`).
  3. HEAD CHECK. The compiled argument's rule HEADS must be inside the
                 agent-conclusion subset (contention + the intermediate pool).
                 The SEAT TEMPLATES are body-only for the agent: an agent rule
                 that concludes one is `head-forgery`.
  4. PREMISES.   Every FACT the argument asserts is looked up in the seat-only
                 engine (the seat facts — call_purpose / forbidden_purpose —
                 with the call's own name NOT yet injected).  Absent ->
                 `premise-false`: the agent's premises are checked against the
                 seat, never taken on its word, and an agent cannot certify its
                 own identity (premise-selfsupport's analog).

Then the query: `justified` over the policy's pinned rule TEXT plus the
argument's rules, with the call binding (call_name) and the seat facts injected.
Zero rows -> `justified-not-derived` — which IS the vacuity verdict: an
argument that never reaches the judgment rule derives nothing, and nothing is
what refuses it.  No vacuity police exists or is needed.

FROZEN TABLES.  SEAT_TEMPLATES and AGENT_CONCLUSIONS are the boundary tables;
they, not comments, are what the checks read, and the gate mutates them to
prove each check can fail.  SEAT_TEMPLATES is also what TYPES the facts dump:
the dump may name a seat template and nothing else, so neither the row binding
(call_name) nor the judgment predicate can reach the engine from outside.

MODES.
  (default)          evaluate a call; exit 0 = derives, 1 = refused by name,
                     2 = tool error.
  --lint-lexicon F   assert the agent lexicon's boundary and exit.
  --compile-policy   compile --policy-le with --policy-lexicon, LINT the
                     result (every head is `justified`; every judgment rule's
                     body mentions at least one seat template — `policy-vacuous`
                     / `policy-foreign-head` otherwise), and print the pinned
                     rule text on stdout.  The ONLY path that produces
                     policy/calls/calls-policy.dl.
  --check-verbs      validate --verbs (the pinned verb table) against
                     --policy-lexicon (verb-undeclared / purpose-undeclared /
                     verb-not-proper / verb-forbidden-flag / verb-duplicate /
                     verb-table-missing).
  --compile-sentence compile --sentence against --policy-lexicon and print the
                     rules — the gate's two-author boundary instrument.
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
# relation -> (arity, column kinds).  Every column here is `sym` (an interned
# string): the calls vocabulary carries no raw-u32 column (unlike the claim
# unit's install mode).
RELATIONS = {
    # the seat's machine facts, injected from the pinned verb table
    "call_purpose": (2, ("sym", "sym")),
    "forbidden_purpose": (1, ("sym",)),
    # injected by THIS evaluator from the call row (the verb the call really is)
    "call_name": (2, ("sym", "sym")),
    # the judgment predicate (host-only; declared so the goal can be queried)
    "justified": (1, ("sym",)),
}

# A seat template: the agent may consume these in a BODY and may never
# manufacture them (the head check below is what enforces it).  These are the
# facts the seat injects through --facts; call_name is the ROW binding injected
# by this evaluator from --call (not from the dump), exactly as eval_claim.py
# separates claim_from/claim_config (row) from generation_config (store).
SEAT_TEMPLATES = frozenset({"call_purpose", "forbidden_purpose"})

# The agent's conclusion subset: the contention predicate plus the intermediate
# pool.  The agent lexicon must declare exactly these (checked by
# --lint-lexicon), so the table and the lexicon cannot drift.
AGENT_CONCLUSIONS = frozenset({"contention", "grounded", "noted"})

JUDGMENT = "justified"
# The OPERATOR author's lever — never this author's.  Its absence from the
# agent lexicon is the two-author boundary, asserted by --lint-lexicon and by
# the gate's two-author arm.
FOREIGN = "denied"

# le's own gap name (le/lower.py:78), quoted back in the refusal so the
# refusal names the compiler gap rather than paraphrasing it.
GAP_CLOSED_LEXICON = "ontology extension (the declared predicate set is closed)"

_ATOM_HEAD = re.compile(r"([a-z][A-Za-z0-9_]*)\s*\(")
_FACT = re.compile(r"\s*([a-z][A-Za-z0-9_]*)\s*\((.*)\)\s*\.\s*\Z", re.S)
_SYMBOL = re.compile(r"[a-z][a-z0-9_]*\Z")
_PROPER = re.compile(r"[A-Za-z]+\Z")


def _tool_error(detail: str, code: int = 2) -> "NoReturn":  # noqa: F821
    print(f"fx-calls: TOOL ERROR: {detail}", file=sys.stderr)
    sys.exit(code)


def _refuse(name: str, detail: str, extra=()) -> "NoReturn":  # noqa: F821
    """A named refusal: exit 1, and the record says WHICH check refused."""
    print(f"# fx-calls: REFUSED -- {name}")
    print(f"verdict\trefused\t{name}")
    print(f"reason\t{detail.replace(chr(9), ' ')}")
    for row in extra:
        print(row)
    sys.exit(1)


def _sha256(path: str) -> str:
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def _read(path: str, what: str) -> str:
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except OSError as exc:
        _tool_error(f"cannot read the {what} at {path}: {exc}")


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


def _load_lexicon(path: str):
    le = _load_le()
    try:
        return le.Lexicon.load(path)
    except le.CompileError as exc:
        _refuse("lexicon", f"{path}: {exc}")
    except OSError as exc:
        _tool_error(f"cannot read the lexicon at {path}: {exc}")


class _Engine:
    """A scratch dlb store: facts in, least-fixpoint queries out."""

    def __init__(self, dlb, relations: dict):
        self.dlb = dlb
        self.dir = tempfile.mkdtemp(prefix="fx-calls-eval-")
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
            # every calls column is sym; a raw-u32 column never appears here
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


def _fold_surface(lexicon, surface: str, sort: str, where: str) -> str:
    """A row's surface name -> the dl symbol the compiler folds to, and it must
    be declared in the lexicon's [names] with the given sort — an undeclared
    id is a loud refusal, never a silent does-not-derive."""
    folded = surface.lower()
    if not _SYMBOL.match(folded):
        _refuse(
            "malformed-call",
            f"{where}: '{surface}' does not fold to a dl symbol "
            "(le/binding.py:144-159)",
        )
    for name, declared_sort in lexicon.names.items():
        if name.lower() == folded:
            if declared_sort != sort:
                _refuse(
                    "undeclared-call-id",
                    f"{where}: '{surface}' is declared in [names] with sort "
                    f"'{declared_sort}', not '{sort}'",
                )
            return folded
    _refuse(
        "undeclared-call-id",
        f"{where}: '{surface}' (dl symbol '{folded}') is not declared in the "
        f"agent lexicon's [names] section with sort '{sort}' — a symbol the "
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
    if FOREIGN in declared:
        _refuse(
            "boundary-reopened",
            f"{path}: the agent lexicon declares '{FOREIGN}' in "
            f"[{declared[FOREIGN]}] -- 'denied' is the OPERATOR author's lever "
            "(policy/ops/), never the claim author's; the two-author boundary "
            "is the mutual absence of each author's predicate",
        )
    if lexicon.actions:
        _refuse(
            "boundary-reopened",
            f"{path}: the agent lexicon declares an [actions] section "
            f"({', '.join(sorted(lexicon.action_preds))}) -- a justification "
            "is declarative; the reactive form is the driver's, not the "
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
    least one seat template.  A judgment rule with no seat-template atom in
    its body judges on the call's own identity + the agent's say-so (the spine
    is gone) and is refused at pin time."""
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
                f"frozen calls policy is '{JUDGMENT}'",
            )
        body = line.split(":-", 1)[1] if ":-" in line else ""
        if not (SEAT_TEMPLATES & set(_ATOM_HEAD.findall(body))):
            _refuse(
                "policy-vacuous",
                f"{where}: the judgment rule's body consumes no seat "
                f"template (one of {sorted(SEAT_TEMPLATES)}) -- it judges on "
                "the call's own name and the agent's say-so with no seat "
                f"spine: {line!r}",
            )


def _compile_policy(args) -> str:
    lexicon = _load_lexicon(args.policy_lexicon)
    text = _read(args.policy_le, "policy")
    le = _load_le()
    try:
        result = le.compile_text(text, lexicon)
    except le.CompileError as exc:
        _refuse("policy-compile", f"{args.policy_le}: {exc}")
    _lint_policy(result.rules, args.policy_le)
    sys.stdout.write(result.rules)
    return result.rules


# ── the verb table (the seam bridge) ──────────────────────────────────────
def _check_verbs(args) -> None:
    lexicon = _load_lexicon(args.policy_lexicon)
    verb_names = {n.lower() for n, s in lexicon.names.items() if s == "verb"}
    purpose_names = {
        n.lower() for n, s in lexicon.names.items() if s == "purpose"
    }
    seen = {}
    rows = []
    forbidden = set()
    for lineno, line in enumerate(_read(args.verbs, "verb table").splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 4 or not all(f.strip() for f in fields):
            _tool_error(
                f"{args.verbs}:{lineno}: a verb row is "
                "verb<TAB>verb-symbol<TAB>purpose<TAB>forbidden "
                f"({len(fields)} field(s): {line!r})"
            )
        verb, vsym, purpose, forb = (f.strip() for f in fields)
        if verb in seen:
            _refuse(
                "verb-duplicate",
                f"{args.verbs}:{lineno}: the runtime verb '{verb}' is already "
                f"mapped on line {seen[verb]}",
            )
        seen[verb] = str(lineno)
        if not _PROPER.match(vsym):
            _refuse(
                "verb-not-proper",
                f"{args.verbs}:{lineno}: the verb-symbol '{vsym}' is not a "
                "proper noun (ASCII letters only) — le compiles proper nouns "
                "to their lowercased symbol, so any other shape could only "
                "ever match nothing (the silent-allow-all direction)",
            )
        if vsym.lower() not in verb_names:
            _refuse(
                "verb-undeclared",
                f"{args.verbs}:{lineno}: the verb-symbol '{vsym}' is not "
                "declared in the lexicon's [names] with sort 'verb' — a verb "
                "symbol the vocabulary cannot name cannot be bound",
            )
        if not _PROPER.match(purpose) or purpose.lower() not in purpose_names:
            _refuse(
                "purpose-undeclared",
                f"{args.verbs}:{lineno}: the purpose '{purpose}' is not "
                "declared in the lexicon's [names] with sort 'purpose'",
            )
        if forb not in ("yes", "no"):
            _refuse(
                "verb-forbidden-flag",
                f"{args.verbs}:{lineno}: the forbidden flag is '{forb}', not "
                "'yes' or 'no'",
            )
        if forb == "yes":
            forbidden.add(purpose.lower())
        rows.append((verb, vsym.lower(), purpose.lower(), forb))
    # THE SHARE FORM, refused as loudly as the drop form: `verb-table-missing`
    # below only catches a symbol mapped by NO runtime verb.  A symbol mapped
    # by TWO (e.g. a typo giving fx_ls the Writeverb symbol fx_write already
    # owns) is the other seam-class error — the call spine is per-symbol, so
    # one contention for the shared symbol would justify BOTH runtime verbs
    # and the rule's demand ("contends for the verb the call really is")
    # silently stops discriminating.
    folded_verb: dict = {}
    for verb, vsym, _purpose, _forb in rows:
        prev = folded_verb.get(vsym)
        if prev is not None:
            _refuse(
                "verb-symbol-duplicate",
                f"{args.verbs}: the verb-symbol '{vsym}' is mapped by BOTH "
                f"'{prev}' and '{verb}' -- two runtime verbs sharing one "
                "abstract symbol would let one contention justify both (the "
                "call spine would stop discriminating)",
            )
        folded_verb[vsym] = verb
    missing = sorted(verb_names - {r[1] for r in rows})
    if missing:
        _refuse(
            "verb-table-missing",
            f"{args.verbs}: the lexicon declares the verb-symbol entries "
            f"{missing} and the table maps none of them -- the lexicon and "
            "the verb table have drifted apart",
        )
    print(f"# fx-calls: verb table OK -- {args.verbs} ({len(rows)} row(s))")
    for verb, vsym, purpose, forb in rows:
        print(f"verb\t{verb}\t{vsym}\tpurpose={purpose}\tforbidden={forb}")
    print(f"# fx-calls: forbidden purposes: "
          f"{','.join(sorted(forbidden)) or '(none)'}")


# ── the two-author boundary instrument ────────────────────────────────────
def _compile_sentence(args) -> None:
    lexicon = _load_lexicon(args.policy_lexicon)
    text = _read(args.sentence, "sentence")
    le = _load_le()
    try:
        result = le.compile_text(text, lexicon)
    except le.CompileError as exc:
        if exc.gap == GAP_CLOSED_LEXICON:
            _refuse(
                "sentence-foreign-predicate",
                f"{args.sentence}: the lexicon is closed and does not "
                f"declare the sentence's predicate -- le refuses by name "
                f"[{GAP_CLOSED_LEXICON}]: {exc}",
            )
        _refuse("sentence-compile-refused", f"{args.sentence}: {exc}")
    sys.stdout.write(result.rules)


# ── the evaluation ────────────────────────────────────────────────────────
def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        prog="eval_calls",
        description="Evaluate a tool call's justification: does justified derive?",
    )
    parser.add_argument("--call", help="the call row (TSV: call<TAB>verb)")
    parser.add_argument("--le", dest="call_le", help="the justification argument (LE)")
    parser.add_argument("--lexicon", help="the AGENT-FACING closed lexicon")
    parser.add_argument("--policy", help="the compiled, pinned policy rule text")
    parser.add_argument("--facts", action="append", default=[],
                        help="the seat's injected facts (call_purpose / "
                             "forbidden_purpose; repeatable)")
    parser.add_argument("--pins", help="the pin file (name<TAB>sha256)")
    parser.add_argument("--lint-lexicon", metavar="PATH",
                        help="assert the agent lexicon's boundary and exit")
    parser.add_argument("--compile-policy", action="store_true",
                        help="compile + lint the policy and print it")
    parser.add_argument("--policy-le")
    parser.add_argument("--policy-lexicon")
    parser.add_argument("--check-verbs", action="store_true",
                        help="validate the pinned verb table and exit")
    parser.add_argument("--verbs")
    parser.add_argument("--compile-sentence", action="store_true",
                        help="compile one LE sentence against the lexicon")
    parser.add_argument("--sentence")
    args = parser.parse_args(argv)

    if args.lint_lexicon:
        lexicon = _load_lexicon(args.lint_lexicon)
        _lint_lexicon(lexicon, args.lint_lexicon)
        print(f"# fx-calls: lexicon OK -- {args.lint_lexicon}")
        print("boundary\tjudgment-in-agent-lexicon=absent\t"
              f"denied-in-agent-lexicon=absent\tactions=none\t"
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

    if args.check_verbs:
        for needed, flag in ((args.verbs, "--verbs"),
                             (args.policy_lexicon, "--policy-lexicon")):
            if not needed:
                _tool_error(f"--check-verbs needs {flag}")
        _check_verbs(args)
        return 0

    if args.compile_sentence:
        for needed, flag in ((args.sentence, "--sentence"),
                             (args.policy_lexicon, "--policy-lexicon")):
            if not needed:
                _tool_error(f"--compile-sentence needs {flag}")
        _compile_sentence(args)
        return 0

    for needed, flag in ((args.call, "--call"), (args.call_le, "--le"),
                         (args.lexicon, "--lexicon"), (args.policy, "--policy")):
        if not needed:
            _tool_error(f"evaluating a call needs {flag}")
    if not args.facts:
        _tool_error("evaluating a call needs at least one --facts dump")

    le = _load_le()
    dlb = _load_dlb()

    # ── step 1: the pin (an unpinned run is STATED, never silent) ──────
    pins = _load_pins(args.pins) if args.pins else {}
    lexicon_sha = _sha256(args.lexicon) if pins else "none"
    policy_sha = _sha256(args.policy) if pins else "none"
    if pins:
        want_lexicon = pins.get("calls-lexicon.ini")
        want_policy = pins.get("calls-policy.dl")
        if not want_lexicon or not want_policy:
            _refuse("pin-incomplete",
                    f"{args.pins}: a pin file must name BOTH "
                    "'calls-lexicon.ini' and 'calls-policy.dl'; it names "
                    f"{sorted(pins)} — the missing entry's file would go "
                    "unverified")
        if lexicon_sha != want_lexicon:
            _refuse("stale-lexicon",
                    f"{args.lexicon}: sha256 {lexicon_sha} is not the pinned "
                    f"{want_lexicon} in {args.pins} — a mutated agent lexicon "
                    "is refused, never silently widened")
        if policy_sha != want_policy:
            _refuse("stale-policy",
                    f"{args.policy}: sha256 {policy_sha} is not the pinned "
                    f"{want_policy} in {args.pins} — re-judgment happens under "
                    "a NEW policy artifact, never a rewritten one")

    lexicon = _load_lexicon(args.lexicon)

    # ── step 2: compile the justification (le, as a dependency) ─────────
    row = _read_call_row(args.call)
    call_surface, verb_surface = row
    call_sym = _fold_surface(lexicon, call_surface, "call", args.call)
    verb_sym = _fold_surface(lexicon, verb_surface, "verb", args.call)
    arg_text = _read(args.call_le, "justification argument")
    try:
        result = le.compile_text(arg_text, lexicon)
    except le.CompileError as exc:
        if exc.gap == GAP_CLOSED_LEXICON:
            _refuse(
                "hostile-compile",
                f"{args.call_le}: the agent lexicon is closed and does not "
                f"declare the sentence's predicate -- le refuses by name "
                f"[{GAP_CLOSED_LEXICON}]: {exc}",
                extra=(f"lexicon\t{args.lexicon}\tsha256={lexicon_sha}",),
            )
        _refuse("compile-refused", f"{args.call_le}: {exc}")

    # ── step 3: the head check (seat templates are body-only) ──────────
    for line in [l for l in result.rules.splitlines() if l.strip()]:
        head = _ATOM_HEAD.match(line)
        if not head:
            _tool_error(f"the compiled argument has a rule with no head: {line!r}")
        pred = head.group(1)
        if pred not in AGENT_CONCLUSIONS:
            _refuse(
                "head-forgery",
                f"{args.call_le}: the argument concludes '{pred}', which is not "
                f"in the agent-conclusion subset {sorted(AGENT_CONCLUSIONS)}; "
                f"the seat templates {sorted(SEAT_TEMPLATES)} are body-only "
                "for the agent — an agent rule may consume the spine, never "
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
                if relation not in SEAT_TEMPLATES:
                    _tool_error(
                        f"{dump}:{lineno}: the dump names the relation "
                        f"'{relation}', which is not a seat template "
                        f"({sorted(SEAT_TEMPLATES)}) -- a facts dump carries "
                        "seat facts only; the call binding and the judgment "
                        "predicate are this evaluator, never the dump"
                    )
                engine.add(relation, engine.columns(relation, fields[1:]))
                stored += 1
        if not stored:
            _tool_error(f"the facts dump(s) {args.facts} hold no facts")

        # ── step 4: premise verification, against the SEAT ONLY ─────────
        for fact in result.facts:
            pred, args_text = _split_fact(fact)
            if pred not in relations:
                _tool_error(f"the compiled argument asserts the unknown {pred}")
            cols = tuple(_col_of_token(engine, a) for a in args_text)
            if not engine.lookup(pred, cols):
                _refuse(
                    "premise-false",
                    f"{args.call_le}: the asserted premise '{fact.strip()}' "
                    "does not derive from the seat's injected facts",
                    extra=(f"facts\tseat-rows={stored}",),
                )

        # the call's binding: injected by the EVALUATOR, never by the argument
        call_col = engine.intern(call_sym)
        verb_col = engine.intern(verb_sym)
        engine.add("call_name", (call_col, verb_col))

        rules_text = _read(args.policy, "policy") + result.rules
        rows = engine.query(rules_text, JUDGMENT)
        # The verdict NAMES the call it judged, so a row for any other symbol
        # would print a verdict the rows do not support.
        foreign = [r for r in rows if len(r) != 1 or r[0] != call_col]
        if foreign:
            named = ", ".join(
                repr(engine.sym_of(r[0])) if len(r) == 1 else repr(r)
                for r in foreign
            )
            _tool_error(
                f"justified derived for symbols other than '{call_sym}': "
                f"{named} -- the verdict names only the call it judged"
            )
    finally:
        engine.close()

    print("# fx-calls: evaluated against the pinned policy + the agent's "
          "argument (free LE over the closed agent lexicon)")
    print(f"call\t{call_sym}\tverb={verb_sym}")
    print("boundary\tjudgment-in-agent-lexicon=absent\t"
          f"denied-in-agent-lexicon=absent\t"
          f"agent-conclusions={','.join(sorted(AGENT_CONCLUSIONS))}\t"
          f"seat-templates={','.join(sorted(SEAT_TEMPLATES))}")
    print(f"pin\tlexicon={lexicon_sha}\tpolicy={policy_sha}")
    print(f"facts\tseat-rows={stored}")
    print(f"agent\tfacts={len(result.facts)}\trules={len(result.rule_lines)}")
    if rows:
        print(f"verdict\tderives\tjustified({call_sym})\trows={len(rows)}")
        return 0
    print("verdict\trefused\tjustified-not-derived")
    print("reason\tzero rows for 'justified' -- the justification does not "
          "reach the frozen policy's judgment rule (a vacuous argument, a "
          "contention that does not match the call's actual verb, or a "
          "forbidden purpose)")
    return 1


def _read_call_row(path: str):
    """The call row: call<TAB>verb (the abstract surfaces the seat resolves
    from the runtime call through the pinned verb table)."""
    rows = []
    for lineno, line in enumerate(_read(path, "call row").splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        rows.append((lineno, line.split("\t")))
    if len(rows) != 1:
        _tool_error(f"{path}: expected exactly one call row, found {len(rows)}")
    lineno, fields = rows[0]
    if len(fields) != 2 or not all(f.strip() for f in fields):
        _refuse(
            "malformed-call",
            f"{path}:{lineno}: a call row is exactly two TAB-separated "
            f"fields (call, verb); got {len(fields)} field(s): {line!r}",
        )
    return tuple(f.strip() for f in fields)


if __name__ == "__main__":
    raise SystemExit(main())
