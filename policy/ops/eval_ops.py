#!/usr/bin/env python3
"""policy/ops/eval_ops.py -- THE OPS-POLICY EVALUATOR (the release seat).

The THIN sibling of policy/eval_claim.py: it owns the OPERATOR policy's
release path — compile, LINT, pin — and nothing else.  The author is the
OPERATOR (never the agent); the policy may only TIGHTEN (deny-more-only:
every rule concludes `denied`, and there is deliberately no allow/`justified`
vocabulary — `justified` is the claim unit's judgment predicate, and the ops
lexicon not declaring it IS the two-author boundary).  `le` is CONSUMED AS A
DEPENDENCY from its own checkout ($LE_DIR), never forked.

THE VOCABULARY SEAM, and why the lint is not enough.  le proper nouns are
letters-only (le/lexicon.py:157-159 refuses `Fx_write` at load) and fold to
lowercased symbols, so a policy that naively spells a runtime symbol or path
matches NOTHING = a silent allow-all.  The ops artifacts are written over a
closed ABSTRACT vocabulary and the binding rides in as seat-injected facts,
so this tool ALSO validates the pinned alias table (--check-aliases): an
unresolvable alias is a LOUD refusal, never a silent non-match.

MODES (exit 0 = ok; 1 = refused by name; 2 = tool error):
  --compile-policy   compile --policy-le with --policy-lexicon, LINT the
                     result and print the pinned rule text on stdout.  The
                     lint: the policy concludes something (policy-vacuous),
                     every head is `denied` (policy-foreign-head), and every
                     deny rule's body mentions at least one SEAT-injected
                     template (policy-vacuous) — a deny rule judging on
                     nothing the seat did not say is refused at pin time.
                     This is the ONLY path that produces
                     policy/ops/ops-policy.dl, so the pin and the lint
                     cannot drift apart.
  --check-aliases    validate --aliases (the pinned alias table) against
                     --policy-lexicon: every row's alias declared with sort
                     `alias` (alias-undeclared), its pathclass with sort
                     `pathclass` (alias-foreign-sort), a yes/no protected
                     flag (alias-protected-flag), an absolute non-empty
                     pattern (alias-bad-pattern), no duplicate alias
                     (alias-duplicate), and every declared alias present
                     (alias-table-missing).  THE PATTERN GRAMMAR IS TWO
                     FORMS, STATED AND ENFORCED (patterns are fnmatch GLOBS
                     matched against the ENTIRE runtime path — NEVER A
                     PREFIX): an EXACT path (no glob characters; matches
                     that one path and nothing else — a bare directory
                     protects the NODE only, never its children) or a
                     SUBTREE '<path>/**' (the path itself and every
                     descendant).  Any other glob shape — a lone '*', '?',
                     '[...]', '**' anywhere but the tail, a trailing '/'
                     (which can never match a runtime path) — is refused
                     (alias-ambiguous-pattern): its coverage cannot be
                     stated in one sentence, and MEASURED (S1 review) a
                     plausible bare-directory row passes a pure absoluteness
                     check and then silently protects nothing but the node.
  --compile-sentence compile --sentence against --policy-lexicon and print
                     the rules; a sentence naming an undeclared predicate is
                     le's own loud GAP_CLOSED_LEXICON, refused here as
                     `sentence-foreign-predicate`.  This is the gate's
                     two-author boundary instrument (ops lexicon vs
                     `justified`; the claim lexicons vs `denied`).
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import sys

# ── the frozen tables ─────────────────────────────────────────────────────
# The ONE head the frozen ops policy may conclude (deny-more-only).
HEAD = "denied"

# The SEAT-injected templates: the policy may CONSUME these in a body and may
# never conclude one (the head check above is what enforces it).  These are
# the atoms whose facts the enforcement seat (slice S2) injects per call or
# at startup; a deny rule mentioning none of them judges on nothing the seat
# said.
SEAT_TEMPLATES = frozenset(
    {"touches", "kind", "class", "protected", "writable", "boot_verdict"}
)

# le's own gap name (le/lower.py:78), quoted back in the refusal so the
# refusal names the compiler gap rather than paraphrasing it.
GAP_CLOSED_LEXICON = "ontology extension (the declared predicate set is closed)"

_ATOM_HEAD = re.compile(r"([a-z][A-Za-z0-9_]*)\s*\(")


def _tool_error(detail: str, code: int = 2) -> "NoReturn":  # noqa: F821
    print(f"fx-ops: TOOL ERROR: {detail}", file=sys.stderr)
    sys.exit(code)


def _refuse(name: str, detail: str) -> "NoReturn":  # noqa: F821
    """A named refusal: exit 1, and the record says WHICH check refused."""
    print(f"# fx-ops: REFUSED -- {name}")
    print(f"verdict\trefused\t{name}")
    print(f"reason\t{detail.replace(chr(9), ' ')}")
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


def _load_lexicon(path: str):
    le = _load_le()
    try:
        return le.Lexicon.load(path)
    except le.CompileError as exc:
        _refuse("lexicon", f"{path}: {exc}")
    except OSError as exc:
        _tool_error(f"cannot read the lexicon at {path}: {exc}")


# ── the policy lint ───────────────────────────────────────────────────────
def _lint_policy(rules_text: str, where: str) -> None:
    """Every head is `denied` (deny-more-only: the frozen policy concludes
    refusals and nothing else), and every deny rule's body consumes at least
    one SEAT-injected template.  A deny rule with no seat template in its
    body judges on nothing the seat said and is refused at pin time —
    the vacuity guard is a property of the POLICY."""
    rules = [line for line in rules_text.splitlines() if line.strip()]
    if not rules:
        _refuse("policy-vacuous", f"{where}: the policy concludes nothing")
    for line in rules:
        head = _ATOM_HEAD.match(line)
        if not head:
            _refuse("policy-foreign-head", f"{where}: not a rule: {line!r}")
        pred = head.group(1)
        if pred != HEAD:
            _refuse(
                "policy-foreign-head",
                f"{where}: the policy concludes '{pred}'; every head of the "
                f"frozen ops policy is '{HEAD}' (deny-more-only: the operator "
                "policy tightens, it never permits)",
            )
        body = line.split(":-", 1)[1] if ":-" in line else ""
        if not (SEAT_TEMPLATES & set(_ATOM_HEAD.findall(body))):
            _refuse(
                "policy-vacuous",
                f"{where}: the deny rule's body consumes no seat-injected "
                f"template (one of {sorted(SEAT_TEMPLATES)}) -- it denies on "
                f"nothing the enforcement seat said: {line!r}",
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


# ── the alias table ───────────────────────────────────────────────────────
def _check_aliases(args) -> None:
    lexicon = _load_lexicon(args.policy_lexicon)
    # The lexicon's [names] is the CLOSED vocabulary: a table row that names
    # something the policy language cannot say is refused here, loudly —
    # left unchecked it would be a silent non-match at enforcement time,
    # which is exactly the allow-all direction the seam finding warns about.
    alias_names = {n.lower() for n, s in lexicon.names.items() if s == "alias"}
    class_names = {
        n.lower() for n, s in lexicon.names.items() if s == "pathclass"
    }
    seen: dict[str, str] = {}
    rows = []
    for lineno, line in enumerate(_read(args.aliases, "alias table").splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 4 or not all(f.strip() for f in fields):
            _tool_error(
                f"{args.aliases}:{lineno}: an alias row is "
                "alias<TAB>pathclass<TAB>protected<TAB>pattern "
                f"({len(fields)} field(s): {line!r})"
            )
        alias, pathclass, protected, pattern = (f.strip() for f in fields)
        folded = alias.lower()
        if folded not in alias_names:
            _refuse(
                "alias-undeclared",
                f"{args.aliases}:{lineno}: the alias '{alias}' is not "
                "declared in the lexicon's [names] with sort 'alias' -- an "
                "alias the policy vocabulary cannot name cannot be written "
                "into a rule, so covering paths under it would be a silent "
                "no-op (the allow-all direction); refused, never unmatched",
            )
        if pathclass.lower() not in class_names:
            _refuse(
                "alias-foreign-sort",
                f"{args.aliases}:{lineno}: the pathclass '{pathclass}' is not "
                "declared in the lexicon's [names] with sort 'pathclass'",
            )
        if protected not in ("yes", "no"):
            _refuse(
                "alias-protected-flag",
                f"{args.aliases}:{lineno}: the protected flag is "
                f"'{protected}', not 'yes' or 'no'",
            )
        if not pattern.startswith("/") or len(pattern) < 2:
            _refuse(
                "alias-bad-pattern",
                f"{args.aliases}:{lineno}: the runtime pattern '{pattern}' is "
                "not an absolute path (it could never match the seat's "
                "runtime paths)",
            )
        # The pattern grammar is TWO STATED FORMS (see the module docstring):
        # an exact path, or '<path>/**' for the subtree.  fnmatch would
        # silently ACCEPT any other glob shape with coverage nobody stated —
        # a lone '*' half-covers (the children, never the node), a trailing
        # '/' matches NOTHING (a silent allow-all) — so the shape is checked,
        # not trusted.
        _GLOBS = ("*", "?", "[")
        has_glob = any(c in pattern for c in _GLOBS)
        if has_glob:
            base = pattern[:-3] if pattern.endswith("/**") else None
            if base is None or not base.startswith("/") or len(base) < 2 \
                    or any(c in base for c in _GLOBS):
                _refuse(
                    "alias-ambiguous-pattern",
                    f"{args.aliases}:{lineno}: the pattern '{pattern}' is "
                    "neither of the two stated shapes -- an EXACT path (no "
                    "glob characters; it matches that path and NEVER its "
                    "children) or a SUBTREE '<path>/**' (the path itself "
                    "and every descendant); free-form globs have unstated "
                    "coverage and are refused, never half-matched",
                )
        elif pattern.endswith("/"):
            _refuse(
                "alias-ambiguous-pattern",
                f"{args.aliases}:{lineno}: the pattern '{pattern}' ends in "
                "'/' -- runtime paths never do, so it would match NOTHING "
                "(a silent allow-all); for the subtree write '<path>/**'",
            )
        coverage = "subtree" if pattern.endswith("/**") else "exact"
        if folded in seen:
            _refuse(
                "alias-duplicate",
                f"{args.aliases}:{lineno}: the alias '{alias}' is already "
                f"mapped on line {seen[folded]}",
            )
        seen[folded] = str(lineno)
        rows.append((alias, pathclass, protected, pattern, coverage))
    missing = sorted(alias_names - set(seen))
    if missing:
        _refuse(
            "alias-table-missing",
            f"{args.aliases}: the lexicon declares the alias sort entries "
            f"{missing} and the table maps none of them -- the lexicon and "
            "the alias table have drifted apart",
        )
    print(f"# fx-ops: alias table OK -- {args.aliases} ({len(rows)} row(s))")
    for alias, pathclass, protected, pattern, coverage in rows:
        # The coverage word restates the grammar at every release: an
        # operator reading the OK output sees that a glob-less row is
        # EXACT-ONLY, never a directory prefix.
        print(f"alias\t{alias}\t{pathclass.lower()}\tprotected={protected}"
              f"\tcoverage={coverage}\t{pattern}")


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


# ── main ──────────────────────────────────────────────────────────────────
def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        prog="eval_ops",
        description="Compile, lint and validate the operator deny policy.",
    )
    parser.add_argument("--compile-policy", action="store_true",
                        help="compile + lint the policy and print it")
    parser.add_argument("--policy-le")
    parser.add_argument("--policy-lexicon")
    parser.add_argument("--check-aliases", action="store_true",
                        help="validate the pinned alias table and exit")
    parser.add_argument("--aliases")
    parser.add_argument("--compile-sentence", action="store_true",
                        help="compile one LE sentence against the lexicon")
    parser.add_argument("--sentence")
    args = parser.parse_args(argv)

    modes = [bool(args.compile_policy), bool(args.check_aliases),
             bool(args.compile_sentence)]
    if sum(modes) != 1:
        _tool_error("exactly one of --compile-policy, --check-aliases, "
                    "--compile-sentence is required")
    if args.compile_policy:
        needed = [("--policy-lexicon", args.policy_lexicon),
                  ("--policy-le", args.policy_le)]
    elif args.check_aliases:
        needed = [("--policy-lexicon", args.policy_lexicon),
                  ("--aliases", args.aliases)]
    else:
        needed = [("--policy-lexicon", args.policy_lexicon),
                  ("--sentence", args.sentence)]
    for flag, value in needed:
        if not value:
            _tool_error(f"this mode needs {flag}")
    if args.compile_policy:
        _compile_policy(args)
        return 0
    if args.check_aliases:
        _check_aliases(args)
        return 0
    _compile_sentence(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
