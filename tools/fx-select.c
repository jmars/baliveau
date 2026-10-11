/* tools/fx-select.c — THE SELECTION STEP of the baliveau harness.
 *
 * THE THIRD SIBLING OF THE ORACLE (tools/fx-osier-share.c), beside the
 * AUDIT (tools/fx-audit.c) and the REPORTER (tools/fx-report.c).  It
 * inherits the family's properties (design record §7.1): HOST-SIDE,
 * AGENT-UNWRITABLE, and a function of OBSERVABLE SYSTEM STATE.  The
 * oracle ASKS "is it better?" and the audit ASKS "is it honest?"; this
 * seat ANSWERS THE QUESTION THE OTHER TWO LEAVE OPEN: WHICH GENERATION
 * SHOULD THE SYSTEM BE RUNNING?
 *
 * ── WHY THIS SEAT EXISTS (design record §7.1, verbatim) ─────────────────
 * "IT IS A TIE-BREAKER, NOT AN OBJECTIVE.  Order of operations: boots ok
 * (viability) -> no drift (`fxstore verify`) -> then maximise the Osier
 * share.  Alone, the metric is satisfiable by shipping Osier that breaks
 * the system; as the last term of a lexicographic order over viable,
 * coherent candidates, it is a real gradient."  MEASURED before this file
 * existed: build/fx-osier-share was invoked ONLY by tests — no loop and no
 * seat consumed its number, so the order lived in prose and nowhere in
 * code.  THIS FILE IS THE ORDER MADE EXECUTABLE.
 *
 * ── THE ORDER (the deliverable; printed as a frozen table on EVERY run,
 *    because a rule that is not printed cannot be audited) ──────────────
 *   1. CANDIDATES  THE BOUNDED SET.  CURRENT comes from `fxstore timeline`'s
 *                  own [CURRENT] mark (the same source the oracle resolves
 *                  from — never a second resolution), and the OTHER
 *                  candidate is THE NEWEST PUBLISHED VERSION BELOW CURRENT
 *                  WHOSE `generation` FACT'S GENHASH DIFFERS FROM CURRENT'S
 *                  and which is not a REPUBLICATION of its immediate
 *                  predecessor (the same genhash — the intermediate
 *                  snapshot a two-snapshot activation or a soft rollback
 *                  publishes carries its PREDECESSOR's system facts,
 *                  MEASURED: generation as-of v6 == as-of v5, v8 == v7).
 *                  The seat asks "IS THE CHANGE WORTH KEEPING?" against the
 *                  incumbent it replaced — not "is ANY historical
 *                  generation better".  Maximising over every published
 *                  version would make the share a global objective rather
 *                  than the TIE-BREAKER §7.1 says it is: any strictly
 *                  lower-share change would be reverted forever, the
 *                  high-water generation would be a permanent attractor
 *                  re-published at a rising version number by every revert,
 *                  and every non-Osier task would be impossible.  Every
 *                  other published version is printed as `not-candidate`
 *                  with its reason and stays in the table as an audit
 *                  record.  When CURRENT has no generation fact the
 *                  predecessor cannot be identified at all: the set is
 *                  {CURRENT} and the state is NAMED.
 *   2. VIABILITY   from <store>/.bootlog ONLY: the LAST non-shutdown line
 *                  naming the version.  ok -> viable.  failed -> not.
 *                  in-progress -> not (no verdict was reached; fx-init's
 *                  own roll-forward treats it as a failure).  no line ->
 *                  not, reason `never-judged`.  Two DAMAGE rules POISON a
 *                  version's verdict, both in the conservative direction
 *                  (a verdict that cannot be read is a hole, not a
 *                  judgement):
 *                    - an unterminated (TORN) last line whose first token
 *                      is the version -> `torn-verdict-unknown`: the file
 *                      was mid-write ABOUT that version (the settled
 *                      direction, src/agent/outcome.c:1032-1035 and the
 *                      RUN-style judgement it poisons —
 *                      tests/test_outcome.sh phase 11);
 *                    - a TERMINATED line that is not the writer's 3-or-4-
 *                      field shape and whose first token NAMES a version ->
 *                      `damaged-line`: the writer never emits that shape, so
 *                      the line's own verdict is unreadable.  This also
 *                      closes the merged-line hole: fx-init appends with
 *                      fopen("a") and NO tail repair (init.zig:764-780), so
 *                      an append after a torn tail MERGES into it and the
 *                      merged line (6+ fields, first token = the version the
 *                      torn write was about) is damaged — the version is
 *                      poisoned instead of falling back to its pre-crash
 *                      verdict.
 *                  Both poisons apply AFTER the clean lines and EVEN when a
 *                  clean verdict exists; when both name one version the TORN
 *                  (end-of-file) one is the state printed.
 *   3. SHARE       per candidate, `fx-osier-share --store <store>
 *                  --as-of <v>` and its `run_set_share_fraction` line —
 *                  THE OBJECTIVE, the oracle's own number, NEVER
 *                  re-derived here.  `closure_share_fraction` is printed
 *                  by the oracle for comparison only and is NEVER read by
 *                  this seat (never averaged in, never substituted): a
 *                  seat that swapped them would be measuring a different
 *                  quantity under the same name.  A candidate the oracle
 *                  REFUSES is EXCLUDED AND NAMED (rule 8) — never
 *                  silently counted as 0%.
 *   4. COHERENCE   `fxstore verify <rootfs> --as-of <CURRENT> --store
 *                  <store>`, exit 0 = no drift — JUDGED FOR CURRENT ONLY.
 *                  The live rootfs corresponds to the CURRENT generation
 *                  alone, so every other candidate prints `not-live` WITH
 *                  that reason and it does NOT affect its eligibility.
 *                  This seat NEVER claims to have verified a generation
 *                  it did not materialize.
 *   5. ELIGIBLE    IN the candidate set AND viable AND (coherent, if it is
 *                  CURRENT).  `not-live` is not a disqualifier; drift is.
 *   6. WINNER      the eligible candidate with the GREATEST share.  A TIE
 *                  GOES TO THE INCUMBENT — a tie NEVER causes a revert.
 *                  (This replaces "the highest version", whose only
 *                  remaining effect in the two-snapshot shape was to prefer
 *                  the half-published intermediate over the generation it
 *                  duplicates; under rule 1 there is no such candidate any
 *                  more, and the rule the gate pins is now the incumbent.)
 *   7. DECISION    `keep <CURRENT>` if the winner is CURRENT, else
 *                  `revert-to <winner>` — and a state the seat would
 *                  REFUSE TO ACT ON is never printed as `revert-to`: it is
 *                  its own frozen NON-ACTIONABLE decision, `withhold
 *                  <state>` (exit 3), with `--apply` reading the SAME
 *                  decision value.  Upheld states (rule 7b below): the
 *                  incumbent's share could not be measured, and the
 *                  incumbent's verdict is unknown (mid-boot `in-progress`,
 *                  torn, or a damaged line naming it) — a booting system is
 *                  not something to roll back.  NO eligible candidate ->
 *                  `no-eligible-candidate`, a NAMED loud state and exit 1 —
 *                  never a silent pick, and never "keep" by default.
 *                  A single predicate `decide()` produces this value, and
 *                  BOTH the printed record and `--apply` read it: the plain
 *                  run and the trigger agree BY CONSTRUCTION, not by two
 *                  matching ifs.
 *   8. EXCLUDED    a candidate the oracle refuses is excluded and NAMED,
 *                  and the count prints as its own caveat line.  An
 *                  excluded CHALLENGER cannot win and blocks nothing (the
 *                  incumbent stays the only eligible candidate); an
 *                  excluded INCUMBENT is rule 7's withhold, because then
 *                  the comparison the revert would rest on was never made.
 *
 * ── WHAT IT READS, and nothing else ────────────────────────────────────
 *   `fxstore timeline --store S`      versions + CURRENT (REUSED)
 *   `fxstore facts generation --as-of v --store S`  each version's
 *                                     genhash, for the candidate bound
 *                                     (rule 1; REUSED, never re-derived
 *                                     from the facts database)
 *   `fxstore verify <rootfs> --as-of CURRENT --store S`  drift (REUSED)
 *   `fxstore rollback <v> --store S`  the trigger, --apply only (REUSED)
 *   `fx-osier-share --store S --as-of v`   the objective (REUSED, by
 *                                          subprocess: ONE measurement,
 *                                          ONE implementation)
 *   <store>/.bootlog                  fx-init's per-boot verdict lines;
 *                                     the WRITER's exact shape
 *                                     (init.zig:769) is
 *                                     "%u %s %u %s\n" =
 *                                     <version> <status> <epoch>
 *                                     <16-hex-nonce|none>, `none` being
 *                                     the writer's placeholder for a boot
 *                                     with no host token (init.zig
 *                                     :888-889, :1008).  A 3-field line is
 *                                     the pre-nonce legacy shape and is
 *                                     TOLERATED because its meaning is
 *                                     statable: the same <version>
 *                                     <status> <epoch> triple from an
 *                                     fx-init that predates the 4th field
 *                                     (fx-report.c's bootev_t calls it
 *                                     "the line predates the nonce field");
 *                                     it carries the same verdict.
 *                                     Any other field count, or a
 *                                     non-numeric version/epoch, is
 *                                     DAMAGED: counted and named, never
 *                                     read as a verdict.
 *   IT NEVER OPENS attempts.jsonl OR ANY OTHER HARNESS SELF-REPORT, and it
 *   never re-implements anything the substrate already does.
 *
 * ── WHY A FOURTH `.bootlog` READER IS JUSTIFIED (measured, not assumed) ─
 * The tree already parses .bootlog in THREE places, and this seat must not
 * pretend otherwise:
 *   (a) src/agent/outcome.c fx_outcome_bootlog_read (in-GUEST, drives the
 *       agent loop's RUN-style judgement).  It is not reachable from a
 *       host tool, and its per-version rule differs by design: it stops at
 *       the FIRST verdict for the generation and poisons a torn tail only
 *       when the generation has NO complete verdict
 *       (`!have_verdict && torn_names == version`, outcome.c:1032-1035).
 *   (b) tools/fx-audit.c read_bootlog + bootlog_last_verdict (:609-660) —
 *       the right per-version semantics (LAST non-shutdown line wins), and
 *       it does carry the 4-field writer shape and a NAMED damaged-line
 *       counter (`g_bl_damaged`); what it does NOT have is this seat's
 *       per-version eligibility rule (a poison of a NAMED version from a
 *       torn tail or a damaged line).  It is also embedded in a VALIDATED
 *       main program with file-static storage, so linking it would mean
 *       splitting a seat that is not in this unit's write scope.
 *   (c) tools/fx-report.c read_bootlog — per-boot EVENT rows for the
 *       report; it has no per-version eligibility rule at all.
 * So this file MIRRORS (b)'s per-version rule (last non-shutdown line
 * wins) and adds the one thing neither (b) nor (c) has: the per-version
 * POISON (torn tail, damaged line) that turns an unreadable verdict into
 * "this candidate is not viable", because a seat that can REVERT must never
 * revert TO a version whose last boot it could not read.  A claim of
 * novelty beyond that would be false: fx-audit.c already parses the same
 * writer shape and already counts damaged lines.
 *
 * ── THE TRIGGER (--apply), and WHY IT IS SOFT ──────────────────────────
 * Default: READ-ONLY.  `--apply` acts on exactly one decision,
 * `revert-to <v>`, by driving the EXISTING `fxstore rollback <v>` — the
 * SOFT path, deliberately, NOT `--hard`:
 *   - SOFT posts the reverted content as a NEW version: the content goes
 *     back and THE VERSION NUMBER GOES UP, which is the substrate's own
 *     roll-forward semantics (README.md:136-138; design record §2).  The
 *     timeline stays append-only and the boot history stays honest — a
 *     version that was booted keeps its record and its number.
 *   - `--hard` is recovery-only ("repoint CURRENT directly, no new
 *     version", fxstore usage): it RENUMBERS AWAY the versions between,
 *     which is a different act with a different meaning.
 *   MEASURED on the fixture: `fxstore rollback 5 --store S` on a 7-version
 *   store published versions 8 and 9 and left CURRENT at 9 with v5's
 *   content — the number went up, as claimed.
 * It REFUSES loudly and mutates NOTHING unless the decision is exactly
 * `revert-to <v>`: `keep` (CURRENT is already the winner — a no-op must
 * never be dressed as an action; exit 0, the decision stands), `withhold`
 * (exit 3) and `no-eligible-candidate` (exit 1) all leave the store
 * untouched.  The withhold states are the conditions under which a revert
 * WOULD be acting on a comparison that was never made (the incumbent
 * unmeasured), on a system that is mid-boot, or on the absence of a verdict
 * (the incumbent never judged — MEASURED: a soft rollback republishes the
 * chosen content under a new, unbooted version, and treating that silence as
 * not-viable made the seat undo its own rollback on the next run); because
 * the plain run prints those states as `withhold` — never as `revert-to` —
 * a harness consuming the frozen record cannot perform the act the trigger
 * refuses.
 *
 * ── OUTPUT, and EXIT CODES ─────────────────────────────────────────────
 * Frozen tab-separated machine records, one frozen tag per line, column
 * order per tag never changing, with a `#` human summary BESIDE them (the
 * house style of tools/fx-report.c).  THE ORDER table and these BOUNDS are
 * part of the output, printed on every run.  Every line is marked MEASURED
 * / DERIVED / ABSENT with the absence's KIND stated.  BYTE-DETERMINISTIC:
 * no wall-clock, no locale, no randomness, no HEAD — two runs over the same
 * store are `cmp`-identical (gated).
 *   0 = an ACTIONABLE decision was produced (`keep` or `revert-to`; with
 *       --apply, the action landed — or was refused because it was a no-op);
 *   1 = NO ELIGIBLE CANDIDATE — a NAMED refusal, never a silent pick;
 *   2 = TOOL ERROR (fxstore or the oracle missing/unusable, an unreadable
 *       record, an unparseable objective, this seat's own bad arguments);
 *   3 = WITHHOLD — the seat has a verdict but will NOT act on it, and says
 *       so in the decision value itself (`withhold <state>`): the incumbent
 *       could not be measured, or its verdict is unknown (mid-boot).  A
 *       consumer that treats non-zero as "no answer" is right; a consumer
 *       that treats `decision revert-to` as the act must never see this
 *       state as one.
 * (fx-audit.c's 0 = coherent / 1 = incoherent / 2 = tool error is the
 * model; this seat's four states differ and are stated here and in usage.)
 */

#include <ctype.h>
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#define MAX_VERSIONS       4096u
#define MAX_BOOTLOG_BYTES  (8u * 1024u * 1024u)
#define LINE_MAX_          8192
#define PATH_MAX_          4096

static const char *g_store  = NULL;              /* --store (REQUIRED) */
static const char *g_rootfs = "/";               /* --rootfs (fxstore verify's own default: the live rootfs) */
static const char *g_fxbin  = NULL;              /* --fxstore / $FXSTORE_BIN / "fxstore" */
static const char *g_oracle = NULL;              /* --oracle / $FX_OSIER_SHARE_BIN / "fx-osier-share" */
static const char *g_pkgset = NULL;              /* --package-set, passed through to the oracle */
static int g_apply = 0;                          /* --apply: the thin trigger */

/* exit codes, stated in the header and the usage text */
#define EX_DECISION    0
#define EX_NO_ELIGIBLE 1
#define EX_TOOL_ERROR  2
#define EX_WITHHOLD    3

/* ── output: machine records + `#` human summary (fx-report.c's rule) ──── */

static void die(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    fputs("fx-select: FAIL: ", stderr);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
    exit(EX_TOOL_ERROR);
}

static void h(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    fputs("# ", stdout);
    vprintf(fmt, ap);
    putchar('\n');
    va_end(ap);
}

static void *xmalloc(size_t n) {
    void *p = malloc(n ? n : 1);
    if (!p) die("out of memory");
    return p;
}

static char *xstrdup(const char *s) {
    size_t n = strlen(s) + 1;
    char *p = xmalloc(n);
    memcpy(p, s, n);
    return p;
}

/* Paths interpolated into a popen'd command: refuse shell metacharacters
 * rather than quote (fx-report.c's check_safe_path, verbatim rule). */
static void check_safe_path(const char *p, const char *what) {
    if (!p[0]) die("empty %s path", what);
    for (const char *q = p; *q; q++)
        if (*q == '\'' || *q == '"' || *q == '\\' || *q == ';' ||
            *q == '$' || *q == '`' || strchr(" \t\n", *q))
            die("unsafe character in %s path: %s", what, p);
}

/* ── the frozen ORDER / BOUNDS tables (part of the output) ─────────────── */

static const struct {
    unsigned step;
    const char *name, *record, *rule;
} ORDER[] = {
 { 1, "candidates", "fxstore timeline --store <store> + fxstore facts generation --as-of <v> --store <store>",
   "THE BOUNDED SET: {CURRENT} + {the NEWEST published version BELOW CURRENT whose generation fact's GENHASH differs from CURRENT's and which is NOT a republication of its immediate predecessor (the same genhash - the intermediate snapshot a two-snapshot activation or soft rollback publishes, which carries its PREDECESSOR's system facts)}. The seat asks IS THE CHANGE WORTH KEEPING? against the incumbent it replaced, not is ANY historical generation better: the share is a TIE-BREAKER (design record 7.1), and a global maximum would make every strictly lower-share change permanently unshippable and every high-water generation a permanent attractor republished at a rising version number. Every other published version prints as not-candidate with its reason and stays as an audit record; a CURRENT with no generation fact leaves the set {CURRENT} and is NAMED" },
 { 2, "viability", "<store>/.bootlog",
   "the LAST non-shutdown line naming the version: ok=viable; failed|in-progress|unknown-status=NOT viable (reason named); no line=NOT viable (never-judged). TWO DAMAGE POISONS override a clean verdict, both preferring the false stop: a TORN (unterminated) last line whose first token names the version (the file was mid-write ABOUT it; outcome.c:1032-1035, test_outcome.sh phase 11), and a TERMINATED line that is not the writer's 3-or-4-field shape and whose first token NAMES the version (the writer never emits it, so its verdict is unreadable - this also closes the torn-then-append MERGE that fx-init's un-repaired append produces, init.zig:764-780). Torn wins the tie between the two" },
 { 3, "share", "fx-osier-share --store <store> --as-of <v>",
   "run_set_share_fraction is THE OBJECTIVE - the oracle's own number, never re-derived here; closure_share_fraction is NEVER read (comparison only, never averaged in, never substituted); a candidate the oracle REFUSES is excluded BY NAME, never counted as 0%" },
 { 4, "coherence", "fxstore verify <rootfs> --as-of <CURRENT> --store <store>",
   "exit 0 = no drift = coherent; judged FOR CURRENT ONLY, because the live rootfs corresponds to the CURRENT generation alone - every other candidate is not-live (NON-disqualifying) and this seat never claims to have verified a generation it did not materialize" },
 { 5, "eligibility", "IN the candidate set AND viable AND (coherent if CURRENT)",
   "a candidate that is not in the bounded set, not viable, or is CURRENT with drift, can NEVER win, whatever its share - the order is ENFORCED, not printed and hoped for" },
 { 6, "winner", "greatest share among ELIGIBLE candidates",
   "A TIE GOES TO THE INCUMBENT: a tie NEVER causes a revert. This replaces tie -> highest version, whose only remaining effect under step 1 was to prefer the half-published intermediate over the generations it duplicates; the tie rule is gated by its own mutant" },
 { 7, "decision", "keep <CURRENT> | revert-to <winner> | withhold <state> | no-eligible-candidate",
   "ONE predicate decides both the printed value and what --apply does, so the plain run and the trigger agree BY CONSTRUCTION. WITHHOLD (exit 3) is the state the seat has a verdict for but will NOT act on, printed as itself and never as revert-to: the incumbent's share could not be measured (current-unmeasured); its verdict is unknown - mid-boot in-progress, a torn tail, or a damaged line naming it (current-verdict-unknown:<state>); or it has never been judged at all (current-not-judged). The last one is MEASURED, not a matter of taste: a soft rollback republishes the chosen content under a NEW version, so the next run's incumbent has silence for a record, and treating that silence as not-viable made the seat revert back to the generation --apply had just left. A CANDIDATE's silence is still rule 2's not-viable - the withholding states are about the incumbent, which is the side the trigger acts against. NO eligible candidate -> a NAMED refusal and exit 1: never a silent pick, never keep-by-default" },
 { 8, "apply", "--apply -> fxstore rollback <winner> --store <store> (SOFT: no --hard)",
   "SOFT because the content returns and the VERSION NUMBER GOES UP - the substrate's own roll-forward semantics, keeping the timeline append-only and the boot history honest; --hard is recovery-only (repoints CURRENT with no new version and renumbers away the versions in between). Acts on revert-to ONLY, and mutates nothing for keep (refused, exit 0: a no-op is not an action), withhold (exit 3) or no-eligible-candidate (exit 1)" },
};

static const struct { const char *id, *text; } BOUNDS[] = {
 { "coherence-not-live",
   "every non-CURRENT candidate's coherence is not-live: this seat measured ONE rootfs, the live one, and reports not-live for the rest rather than implying a verification it did not run. Consequence, stated rather than left to be discovered: the no-drift term is a veto on the INCUMBENT only, so a revert can name a generation that would itself drift once materialized - the seat sees that on its NEXT run, as the new CURRENT drifting, and would then revert again. In the deployment the next boot materializes the rolled-back generation before the seat runs again; a loop that drives --apply WITHOUT a boot in between can oscillate once" },
 { "candidate-set-is-a-pair",
   "the bound is CURRENT + the ONE generation it replaced. A better generation OLDER than that predecessor is not a candidate and this seat cannot select it: the bound trades that reach for the property that makes the metric a tie-breaker rather than a permanent objective (rule 1). The full version table is still printed, so the reader can see what the bound excludes and why" },
 { "share-of-a-partial-snapshot",
   "an activation can publish an INTERMEDIATE snapshot whose run set is still empty; the oracle measures it as run_set_share_fraction 0/0 = 0.000000 and this seat reports THAT number - it never re-derives a 'real' one from the finished snapshot (ONE measurement, ONE implementation)" },
 { "damage-poisons-only-what-it-names",
   "both damage poisons fire on the version a damaged or torn line NAMES - i.e. on its first token - which for the merged-line shape is the version the interrupted write was about. A damaged line whose first token is not a published version poisons nothing (it is still counted and caveated): the seat does not guess which version a garbled line was about, and it does not fall back to a verdict it could not read" },
 { "bootlog-is-in-guest-writable",
   "root in-guest can forge or truncate .bootlog exactly as it can .recovery: this seat's viability term is a function of a record the suspect can edit. Catching that is the AUDIT seat's previous-observation comparison, not this seat's job" },
 { "incumbent-unmeasured",
   "when the oracle refuses for CURRENT its share is unknown and the seat WITHHOLDS (exit 3, state current-unmeasured, printed by the same predicate --apply reads), because acting on an unmeasured incumbent is acting on half the comparison. An oracle-refusing CHALLENGER is the mirror case and blocks nothing: it is excluded BY NAME, cannot win, and the measured incumbent stays the only eligible candidate - so the seat invents no comparison it could not make, in either direction" },
};

static void print_order_table(void) {
    for (size_t i = 0; i < sizeof ORDER / sizeof *ORDER; i++)
        printf("order\t%u\t%s\t%s\t%s\n", ORDER[i].step, ORDER[i].name,
               ORDER[i].record, ORDER[i].rule);
    for (size_t i = 0; i < sizeof BOUNDS / sizeof *BOUNDS; i++)
        printf("bound\t%s\t%s\n", BOUNDS[i].id, BOUNDS[i].text);
}

/* ── running the substrate's own tools (read-only by subprocess) ───────── */

/* Run CMD, capture stdout (+stderr, see below).  Returns the captured text
 * (caller frees) and the exit status via *rc. */
static char *run_capture(const char *cmd, int *rc) {
    FILE *p = popen(cmd, "r");
    if (!p) die("cannot popen '%s' (%s)", cmd, strerror(errno));
    size_t cap = 65536, len = 0;
    char *buf = xmalloc(cap);
    char line[LINE_MAX_];
    while (fgets(line, sizeof line, p)) {
        size_t ll = strlen(line);
        if (len + ll + 1 > cap) {
            while (len + ll + 1 > cap) cap *= 2;
            char *nb = realloc(buf, cap);
            if (!nb) die("out of memory");
            buf = nb;
        }
        memcpy(buf + len, line, ll + 1);
        len += ll;
    }
    int st = pclose(p);
    *rc = WIFEXITED(st) ? WEXITSTATUS(st) : -1;
    if (len == 0) buf[0] = 0;
    return buf;
}

/* The first line of a captured blob (for NAMING a refusal), trimmed and
 * bounded; empty when the blob carries no line at all. */
static void first_line(const char *blob, char *out, size_t cap) {
    size_t i = 0;
    if (!blob) { out[0] = 0; return; }
    while (blob[i] && blob[i] != '\n' && i + 1 < cap) { out[i] = blob[i]; i++; }
    out[i] = 0;
    while (i && (out[i - 1] == '\r' || out[i - 1] == ' ')) out[--i] = 0;
}

/* ── the store's published versions, and CURRENT ───────────────────────── */

typedef struct {
    unsigned v;
    int is_current;
} ver_t;

static ver_t   g_vers[MAX_VERSIONS];
static unsigned g_nvers;
static unsigned g_current;

static void read_timeline(void) {
    if (!g_fxbin) {
        const char *fb = getenv("FXSTORE_BIN");
        g_fxbin = xstrdup((fb && *fb) ? fb : "fxstore");
    }
    check_safe_path(g_store, "--store");
    check_safe_path(g_fxbin, "--fxstore/FXSTORE_BIN");
    char *cmd;
    if (asprintf(&cmd, "'%s' timeline --store '%s' 2>&1", g_fxbin, g_store) < 0)
        die("out of memory");
    int rc;
    char *out = run_capture(cmd, &rc);
    free(cmd);
    if (rc != 0) {
        char m[512]; first_line(out, m, sizeof m);
        free(out);
        die("'fxstore timeline --store %s' failed (exit %d): %s — cannot read the store's versions",
            g_store, rc, m[0] ? m : "(no output)");
    }
    unsigned any = 0, cur = 0;
    char *save = NULL;
    for (char *tok = strtok_r(out, "\n", &save); tok; tok = strtok_r(NULL, "\n", &save)) {
        unsigned v;
        if (sscanf(tok, " %u", &v) != 1) continue;
        any = v;
        if (strstr(tok, "[CURRENT]")) cur = v;
        if (g_nvers >= MAX_VERSIONS)
            die("store %s lists more than %u versions — refusing to enumerate a timeline this size",
                g_store, MAX_VERSIONS);
        g_vers[g_nvers].v = v;
        g_vers[g_nvers].is_current = 0;
        g_nvers++;
    }
    free(out);
    if (!any) die("store %s has no published snapshot — there is nothing to select", g_store);
    if (!cur)
        die("store %s marks no CURRENT snapshot (newest is %u) — the live generation is unknown, and a decision that guesses it is not a decision",
            g_store, any);
    for (unsigned i = 0; i < g_nvers; i++)
        if (g_vers[i].v == cur) g_vers[i].is_current = 1;
    g_current = cur;
}

/* ── viability: <store>/.bootlog ONLY ──────────────────────────────────── */

/* Absent vs unreadable is the distinction the in-guest reader paid for
 * (outcome.c:525-536: glibc's fopen() succeeds on a directory and the first
 * read fails — the read error is the ABSENCE OF EVIDENCE, not evidence of
 * nothing).  Absent is a STATE (this store has not booted); unreadable is a
 * TOOL ERROR here, because this seat's viability term would otherwise read
 * as `never-judged` off a measurement that was never made. */
static char *read_file(const char *path, size_t *len_out, int *absent) {
    *absent = 0; *len_out = 0;
    FILE *f = fopen(path, "rb");
    if (!f) {
        if (errno == ENOENT) { *absent = 1; return NULL; }
        die("cannot open '%s': %s — the bootlog exists but cannot be read, so no candidate's viability can be judged", path, strerror(errno));
    }
    if (fseek(f, 0, SEEK_END) != 0) die("cannot seek '%s': %s", path, strerror(errno));
    long sz = ftell(f);
    if (sz < 0) die("cannot tell '%s': %s", path, strerror(errno));
    if ((unsigned long)sz > MAX_BOOTLOG_BYTES)
        die("'%s' is %ld bytes (cap %u) — refusing to read a record this size", path, sz, MAX_BOOTLOG_BYTES);
    rewind(f);
    char *b = xmalloc((size_t)sz + 1);
    if (sz > 0 && fread(b, 1, (size_t)sz, f) != (size_t)sz)
        die("short read on '%s' (%ld bytes): %s", path, sz, strerror(errno));
    if (ferror(f)) die("cannot read '%s': %s", path, strerror(errno));
    fclose(f);
    b[sz] = 0;
    *len_out = (size_t)sz;
    return b;
}

/* the per-version viability state, frozen vocabulary */
enum { VIA_NONE = 0, VIA_OK, VIA_FAILED, VIA_INPROGRESS, VIA_UNKNOWN,
       VIA_NEVER, VIA_TORN, VIA_DAMAGED };

static const char *via_name(int s) {
    switch (s) {
    case VIA_OK:          return "ok";
    case VIA_FAILED:      return "failed";
    case VIA_INPROGRESS:  return "in-progress";
    case VIA_UNKNOWN:     return "unknown-verdict";
    case VIA_NEVER:       return "never-judged";
    case VIA_TORN:        return "torn-verdict-unknown";
    case VIA_DAMAGED:     return "damaged-line";
    default:              return "never-judged";
    }
}

typedef struct {
    int      state;              /* VIA_* */
    char     reason[320];        /* the line it came from, or the absence's kind */
    unsigned line;               /* .bootlog line number, 0 when no line */
} via_t;

static via_t g_via[MAX_VERSIONS];
static unsigned g_damaged_line[MAX_VERSIONS];  /* .bootlog line that damaged it, 0 = none */
static unsigned g_damaged_fields[MAX_VERSIONS];

static long ver_index_of(unsigned v) {
    for (unsigned i = 0; i < g_nvers; i++) if (g_vers[i].v == v) return (long)i;
    return -1;
}

/* A line is only real if it is TERMINATED (outcome.c:492-511's rule and the
 * reason it gives: fx-init's bootlog_append writes one fprintf per line and
 * fsyncs, so an unterminated tail is a crash mid-write, and a prefix cut
 * inside a field can still parse).  A torn tail's VERSION token, when that
 * much survived, is kept: the file was mid-write ABOUT that generation. */
static void read_bootlog(void) {
    char path[PATH_MAX_];
    snprintf(path, sizeof path, "%s/.bootlog", g_store);
    size_t len = 0;
    int absent = 0;
    char *buf = read_file(path, &len, &absent);
    for (unsigned i = 0; i < g_nvers; i++) {
        g_via[i].state = VIA_NEVER;
        g_via[i].line = 0;
        snprintf(g_via[i].reason, sizeof g_via[i].reason,
                 absent ? "no .bootlog in this store (it has never booted): absence kind = the file is NOT THERE"
                        : "no line of .bootlog names this version: absence kind = never judged");
    }
    if (absent) { free(buf); return; }

    unsigned lineno = 0, damaged = 0, torn = 0;
    unsigned torn_names = 0;
    int torn_names_ok = 0;
    char *p = buf, *end = buf + len;
    while (p < end) {
        char *nl = memchr(p, '\n', (size_t)(end - p));
        size_t llen = nl ? (size_t)(nl - p) : (size_t)(end - p);
        lineno++;
        if (!nl) {
            /* torn tail */
            torn++;
            unsigned long tv = 0;
            char *tmp = xmalloc(llen + 1);
            memcpy(tmp, p, llen);
            tmp[llen] = 0;
            if (!torn_names_ok && sscanf(tmp, "%lu", &tv) == 1) {
                torn_names = (unsigned)tv;
                torn_names_ok = 1;
            }
            free(tmp);
            break;
        }
        /* tokenize the terminated line by whitespace: the writer's shape is
         * exactly 3 (pre-nonce legacy) or 4 (%u %s %u %s) fields */
        char *tmp = xmalloc(llen + 1);
        memcpy(tmp, p, llen);
        tmp[llen] = 0;
        char *f[6] = {0};
        int nf = 0;
        char *q = tmp;
        while (*q) {
            while (*q == ' ' || *q == '\t') q++;
            if (!*q) break;
            if (nf < 6) f[nf] = q;
            nf++;
            while (*q && *q != ' ' && *q != '\t') q++;
            if (*q) *q++ = 0;
        }
        int ok = 0;
        if ((nf == 3 || nf == 4) && f[0] && f[1] && f[2]) {
            ok = 1;
            for (const char *d = f[0]; *d; d++) if (!isdigit((unsigned char)*d)) ok = 0;
            for (const char *d = f[2]; *d; d++) if (!isdigit((unsigned char)*d)) ok = 0;
            if (nf == 4 && (!f[3] || !f[3][0])) ok = 0;
        }
        if (!ok) {
            /* terminated but not the writer's shape: damaged, counted and
             * named — and, when its first token NAMES a published version,
             * it POISONS that version (rule 2): the writer never emits a
             * 5+-field line, so the line's own verdict is unreadable, and a
             * seat that can revert must never revert TO a version whose last
             * boot it could not read.  This is also the MERGED-LINE hole:
             * fx-init appends with fopen("a") and no tail repair
             * (init.zig:764-780), so a line appended after a torn tail joins
             * the fragment and the merged line's first token is the version
             * the interrupted write was about. */
            damaged++;
            {
                unsigned long dv = 0;
                char *dend = NULL;
                int numeric = f[0] && f[0][0];
                for (const char *q2 = f[0]; q2 && *q2; q2++)
                    if (!isdigit((unsigned char)*q2)) numeric = 0;
                if (numeric) {
                    dv = strtoul(f[0], &dend, 10);
                    long di = ver_index_of((unsigned)dv);
                    if (di >= 0) {
                        g_damaged_line[di] = lineno;
                        g_damaged_fields[di] = (unsigned)nf;
                    }
                }
            }
            free(tmp);
            p = nl + 1;
            continue;
        }
        unsigned v = (unsigned)strtoul(f[0], NULL, 10);
        const char *status = f[1];
        long idx = ver_index_of(v);
        if (idx >= 0 && strcmp(status, "shutdown") != 0) {
            via_t *t = &g_via[idx];
            t->line = lineno;
            if (!strcmp(status, "ok"))            t->state = VIA_OK;
            else if (!strcmp(status, "failed"))   t->state = VIA_FAILED;
            else if (!strcmp(status, "in-progress")) t->state = VIA_INPROGRESS;
            else                                  t->state = VIA_UNKNOWN;
            snprintf(t->reason, sizeof t->reason,
                     "last non-shutdown line naming v%u is \"%s\" (.bootlog line %u, %d field(s)%s)",
                     v, status, lineno, nf, nf == 3 ? ", the pre-nonce legacy shape" : "");
        }
        free(tmp);
        p = nl + 1;
    }
    free(buf);

    /* the damaged poison first, then the torn one: when both name one
     * version the torn (end-of-file) state is the one printed */
    for (unsigned i = 0; i < g_nvers; i++) {
        if (!g_damaged_line[i]) continue;
        g_via[i].state = VIA_DAMAGED;
        snprintf(g_via[i].reason, sizeof g_via[i].reason,
                 ".bootlog line %u names v%u and is DAMAGED: %u fields, not the writer's 3 or 4 (init.zig:769) — the line's verdict is unreadable, so this version's verdict is UNKNOWN rather than whatever its last clean line said (prefer the false stop)",
                 g_damaged_line[i], g_vers[i].v, g_damaged_fields[i]);
    }
    if (torn_names_ok) {
        long idx = ver_index_of(torn_names);
        if (idx >= 0) {
            g_via[idx].state = VIA_TORN;
            snprintf(g_via[idx].reason, sizeof g_via[idx].reason,
                     "the LAST line of .bootlog is unterminated (torn) and its version token is %u: the verdict is UNKNOWN — the file was mid-write about this version, so an earlier verdict cannot be trusted to speak for it (prefer the false stop)",
                     torn_names);
        }
    }
    if (damaged || torn)
        printf("caveat\tbootlog-damage\tdamaged=%u\ttorn=%u\t%s\n", damaged, torn,
               "damaged = a TERMINATED line that is not the writer's 3-or-4-field shape (never read as a verdict); torn = an UNTERMINATED final line (a crash mid-write, its version token recorded)");
}

/* ── share: the oracle, by subprocess (ONE measurement, ONE impl) ──────── */

typedef struct {
    int    measured;             /* 1 measured, 0 refused by the oracle */
    double share;
    char   share_s[32];          /* the oracle's OWN string, printed verbatim */
    char   bytes[48];            /* osier/total, the objective's own domain */
    int    rc;                   /* the oracle's exit status */
    char   refusal[512];         /* the oracle's own first line, when refused */
} share_t;

static share_t g_share[MAX_VERSIONS];

static void resolve_oracle(void) {
    if (!g_oracle) {
        const char *ob = getenv("FX_OSIER_SHARE_BIN");
        g_oracle = xstrdup((ob && *ob) ? ob : "fx-osier-share");
    }
    check_safe_path(g_oracle, "--oracle/FX_OSIER_SHARE_BIN");
    if (g_pkgset) check_safe_path(g_pkgset, "--package-set");
}

/* PROBE the oracle LOUDLY, before any candidate is measured: a missing or
 * unrunnable oracle is a TOOL ERROR, never a 0% (this seat's invariant ii).
 * The probe is cheap and deliberately not a measurement — an oracle that
 * answers `--help` yet refuses candidates is NOT caught here: each refusal is
 * a named exclusion (rule 8) and, when it is the INCUMBENT that was refused,
 * the decision becomes the withhold state current-unmeasured, whose reason
 * names the count of refusals. */
static void probe_oracle(void) {
    char *cmd;
    if (asprintf(&cmd, "'%s' --help >/dev/null 2>&1", g_oracle) < 0) die("out of memory");
    int rc;
    char *out = run_capture(cmd, &rc);
    free(out);
    free(cmd);
    if (rc != 0)
        die("the oracle '%s' cannot be run (--help exited %d) — pass --oracle PATH or set FX_OSIER_SHARE_BIN; a seat that reads a missing measurement as 0%% is worse than no seat",
            g_oracle, rc);
}

static void measure_share(unsigned v, share_t *s) {
    if (!g_fxbin) {
        const char *fb = getenv("FXSTORE_BIN");
        g_fxbin = xstrdup((fb && *fb) ? fb : "fxstore");
    }
    /* the oracle resolves its fxstore from $FXSTORE_BIN: hand it the SAME
     * binary this seat was told to use, so the two never disagree about
     * which store they are reading */
    setenv("FXSTORE_BIN", g_fxbin, 1);
    char *cmd;
    if (g_pkgset)
        asprintf(&cmd, "'%s' --store '%s' --as-of %u --package-set '%s' 2>&1",
                 g_oracle, g_store, v, g_pkgset);
    else
        asprintf(&cmd, "'%s' --store '%s' --as-of %u 2>&1", g_oracle, g_store, v);
    if (!cmd) die("out of memory");
    int rc;
    char *out = run_capture(cmd, &rc);
    free(cmd);
    if (rc != 0) {
        s->measured = 0;
        s->rc = rc;
        first_line(out, s->refusal, sizeof s->refusal);
        free(out);
        return;
    }
    /* parse the OBJECTIVE only.  `run_set_share_fraction` is its own line
     * and its own quantity; `closure_share_fraction` is never touched. */
    s->measured = 0;
    s->share_s[0] = 0;
    s->bytes[0] = 0;
    unsigned long osier = 0, total = 0;
    int have_osier = 0, have_total = 0;
    char *save = NULL;
    for (char *t = strtok_r(out, "\n", &save); t; t = strtok_r(NULL, "\n", &save)) {
        if (strncmp(t, "run_set_share_fraction ", 23) == 0) {
            double d = 0;
            if (sscanf(t + 23, "%lf", &d) != 1) break;
            snprintf(s->share_s, sizeof s->share_s, "%s", t + 23);
            s->share = d;
            s->measured = 1;
        } else if (strncmp(t, "run_set_osier_bytes ", 20) == 0) {
            if (sscanf(t + 20, "%lu", &osier) == 1) have_osier = 1;
        } else if (strncmp(t, "run_set_total_bytes ", 20) == 0) {
            if (sscanf(t + 20, "%lu", &total) == 1) have_total = 1;
        }
    }
    if (have_osier && have_total)
        snprintf(s->bytes, sizeof s->bytes, "%lu/%lu", osier, total);
    free(out);
    if (!s->measured)
        die("the oracle exited 0 for v%u but printed no 'run_set_share_fraction' line — an objective that cannot be read is a TOOL ERROR, never an exclusion and never a 0%%",
            v);
}

/* ── coherence: fxstore verify, judged FOR CURRENT ONLY ────────────────── */

enum { COH_CLEAN = 0, COH_DRIFT, COH_NOTLIVE };

typedef struct {
    unsigned v;
    int      state;
    char     reason[720];
    unsigned n_drift;
    int      n_from;   /* 1 = the count came from fxstore's own header line */
} coh_t;

static coh_t g_coh = { 0, COH_NOTLIVE, "", 0, 0 };

static void verify_current(void) {
    char *cmd;
    if (asprintf(&cmd, "'%s' verify '%s' --as-of %u --store '%s' 2>&1",
                 g_fxbin, g_rootfs, g_current, g_store) < 0)
        die("out of memory");
    int rc;
    char *out = run_capture(cmd, &rc);
    free(cmd);
    g_coh.v = g_current;
    if (rc == 0) {
        g_coh.state = COH_CLEAN;
        snprintf(g_coh.reason, sizeof g_coh.reason,
                 "fxstore verify '%s' --as-of v%u exited 0: the live rootfs reconciles against the CURRENT generation's install facts",
                 g_rootfs, g_current);
        free(out);
        return;
    }
    char m[512]; first_line(out, m, sizeof m);
    if (strstr(out, "no such version")) {
        free(out);
        die("fxstore verify --as-of v%u says 'no such version' — the [CURRENT] mark names a version the store does not hold; the store is inconsistent and nothing can be decided from it",
            g_current);
    }
    if (rc != 1) {
        free(out);
        die("fxstore verify '%s' --as-of v%u failed with exit %d (%s) — cannot judge the live generation's coherence",
            g_rootfs, g_current, rc, m[0] ? m : "no output");
    }
    /* rc 1 == drift (measured: the verify header carries the count, and one
     * line per drifting target follows it) */
    /* the header is `<rootfs> against store <store>: N drift(s)` and the
     * count must be READ FROM IT, not discovered by counting the lines that
     * follow (an instrument that can only ever answer 1 is not measuring
     * anything).  Walk back from the "drift" token over the digits rather
     * than hunting a separator: the shape belongs to fxstore, not to this
     * seat's guess about it. */
    unsigned n = 0, lines = 0;
    int from_header = 0;
    char first_drift[512] = "";
    char *save = NULL;
    for (char *t = strtok_r(out, "\n", &save); t; t = strtok_r(NULL, "\n", &save)) {
        if (strncmp(t, "fxstore: verify ", 16) == 0) {
            const char *d = strstr(t, "drift");
            if (d) {
                const char *q = d;
                while (q > t && q[-1] == ' ') q--;
                const char *e = q;
                while (e > t && isdigit((unsigned char)e[-1])) e--;
                if (e < q) { n = (unsigned)strtoul(e, NULL, 10); from_header = 1; }
            }
            continue;
        }
        lines++;
        if (!first_drift[0]) snprintf(first_drift, sizeof first_drift, "%s", t);
    }
    free(out);
    if (!from_header) n = lines;   /* and SAY SO: the count is then DERIVED */
    g_coh.state = COH_DRIFT;
    g_coh.n_drift = n;
    g_coh.n_from = (int)from_header;
    snprintf(g_coh.reason, sizeof g_coh.reason,
             "fxstore verify '%s' --as-of v%u exited 1: %u drift(s) against the install facts (count %s), first: %s",
             g_rootfs, g_current, n,
             from_header ? "read from fxstore's own header" : "DERIVED by counting the drift lines (the header did not parse)",
             first_drift[0] ? first_drift : "(no drift line)");
}

/* ── the candidate bound: CURRENT and the generation it replaced ───────── */

/* Each version's `generation` fact (fxstore facts generation:
 * `<genhash> <buildfile> <dhake> <epoch>`).  MEASURED on the gate's fixture:
 * the intermediate snapshot a two-snapshot activation publishes carries its
 * PREDECESSOR's generation facts (generation as-of v6 == as-of v5, v4 == v3),
 * and a soft rollback's intermediate likewise (v8 == v7) — that is what makes
 * "not a republication of its immediate predecessor" the right test for
 * "this is a distinct change" rather than "this is half a publish". */
typedef struct { int read; int present; char gh[80]; } gh_t;
static gh_t     g_gh[MAX_VERSIONS];
static unsigned g_gh_err;   /* versions whose generation fact could not be read */

typedef struct { int is_cand; char ncr[320]; } candb_t;
static candb_t  g_candb[MAX_VERSIONS];
static long     g_pred = -1;      /* index of the predecessor candidate */
static unsigned g_ncand;
static char     g_bound_note[400];

static void read_genhash(long idx) {
    if (idx < 0 || idx >= (long)g_nvers) return;
    gh_t *g = &g_gh[idx];
    if (g->read) return;
    g->read = 1;
    char *cmd;
    if (asprintf(&cmd, "'%s' facts generation --as-of %u --store '%s' 2>&1",
                 g_fxbin, g_vers[idx].v, g_store) < 0)
        die("out of memory");
    int rc;
    char *out = run_capture(cmd, &rc);
    free(cmd);
    if (rc != 0) {
        /* a version with NO generation fact exits 0 with no output — that is
         * an ABSENT genhash, not an error.  A non-zero exit is something
         * else, so it is counted and named rather than folded into absence. */
        g_gh_err++;
        free(out);
        return;
    }
    char line[256];
    first_line(out, line, sizeof line);
    free(out);
    if (!line[0]) return;                  /* present = 0: no generation fact */
    char *tab = strchr(line, '\t');
    if (tab) *tab = 0;
    snprintf(g->gh, sizeof g->gh, "%s", line);
    g->present = 1;
}

static const char *CANDIDATE_RULE =
    "CANDIDATES = {CURRENT} + {the NEWEST published version BELOW CURRENT whose generation fact's GENHASH DIFFERS from CURRENT's and which is NOT a republication of its immediate predecessor (the same genhash: the intermediate snapshot a two-snapshot activation or soft rollback leaves behind, carrying its PREDECESSOR's system facts)}. The question is IS THE CHANGE WORTH KEEPING? against the incumbent it replaced - the share is a TIE-BREAKER (design record 7.1), not an objective over all of history";

static void compute_bound(void) {
    long curi = ver_index_of(g_current);
    g_pred = -1;
    g_ncand = 0;
    g_bound_note[0] = 0;
    for (unsigned i = 0; i < g_nvers; i++) {
        g_candb[i].is_cand = 0;
        snprintf(g_candb[i].ncr, sizeof g_candb[i].ncr, "outside-the-bound");
    }
    if (curi < 0) return;                  /* CURRENT is in the timeline by construction */
    g_candb[curi].is_cand = 1;
    g_candb[curi].ncr[0] = 0;
    g_ncand = 1;
    read_genhash(curi);
    if (!g_gh[curi].present) {
        snprintf(g_bound_note, sizeof g_bound_note,
                 "CURRENT v%u has NO generation fact, so the generation it replaced cannot be identified: the candidate set is {CURRENT} alone and no comparison is possible",
                 g_current);
        for (unsigned i = 0; i < g_nvers; i++)
            if (!g_candb[i].is_cand)
                snprintf(g_candb[i].ncr, sizeof g_candb[i].ncr,
                         "predecessor-unidentified: CURRENT v%u has no generation fact to compare against", g_current);
        return;
    }
    for (long j = curi - 1; j >= 0; j--) {
        read_genhash(j);
        if (!g_gh[j].present) {
            snprintf(g_candb[j].ncr, sizeof g_candb[j].ncr,
                     "no-generation-fact: published with no system facts, so it is not a generation this seat can compare (the walk continues below it)");
            continue;
        }
        if (strcmp(g_gh[j].gh, g_gh[curi].gh) == 0) {
            snprintf(g_candb[j].ncr, sizeof g_candb[j].ncr,
                     "same-generation-as-current: genhash %s equals CURRENT v%u's — a later snapshot of the generation already running, not a distinct change", g_gh[j].gh, g_current);
            continue;
        }
        long pj = j - 1;
        read_genhash(pj);
        if (pj >= 0 && g_gh[pj].present && strcmp(g_gh[j].gh, g_gh[pj].gh) == 0) {
            snprintf(g_candb[j].ncr, sizeof g_candb[j].ncr,
                     "republication-of-its-immediate-predecessor: genhash %s equals v%u's — the INTERMEDIATE snapshot a two-snapshot publish leaves behind, carrying its predecessor's system facts (never a candidate: it is the same generation republished, and under the old tie rule it was the thing the seat preferred)", g_gh[j].gh, g_vers[pj].v);
            continue;
        }
        g_pred = j;
        g_candb[j].is_cand = 1;
        g_candb[j].ncr[0] = 0;
        g_ncand++;
        break;
    }
    /* every version the walk never reached still gets a NAMED reason */
    for (unsigned i = 0; i < g_nvers; i++) {
        if (g_candb[i].is_cand) continue;
        if (strcmp(g_candb[i].ncr, "outside-the-bound") != 0) continue;
        if (g_vers[i].v > g_current)
            snprintf(g_candb[i].ncr, sizeof g_candb[i].ncr,
                     "above-current: the bound spans the incumbent and the change it replaced (a `fxstore rollback --hard` can leave versions above CURRENT; they are not candidates here)");
        else if (g_pred >= 0)
            snprintf(g_candb[i].ncr, sizeof g_candb[i].ncr,
                     "older-than-the-predecessor v%u: outside the bound, which compares ONLY the incumbent with the change it replaced (the full table is printed as an audit record, and this seat cannot select a generation older than the one the change replaced)", g_vers[g_pred].v);
        else
            snprintf(g_candb[i].ncr, sizeof g_candb[i].ncr,
                     "older-than-CURRENT-with-no-predecessor-identified: outside the bound");
    }
}

/* ── the sweep, the frozen records, the order ENFORCED ─────────────────── */

static void usage(FILE *f) {
    fprintf(f,
        "fx-select — THE SELECTION STEP (host-side; READ-ONLY unless --apply)\n"
        "usage: fx-select --store DIR [--rootfs DIR] [--fxstore BIN] [--oracle BIN]\n"
        "                  [--package-set PATH] [--apply]\n"
        "  --store DIR      the store to select over (REQUIRED; a seat that guesses\n"
        "                   which store it is deciding about is guessing the decision)\n"
        "  --rootfs DIR     a host view of the LIVE rootfs, judged against CURRENT\n"
        "                   only (default / — fxstore verify's own default rootfs)\n"
        "  --fxstore BIN    fxstore binary (default $FXSTORE_BIN, else PATH); also\n"
        "                   handed to the oracle as FXSTORE_BIN so the two agree\n"
        "  --oracle BIN     the objective's binary (default $FX_OSIER_SHARE_BIN,\n"
        "                   else fx-osier-share); PROBED, and a missing one is a\n"
        "                   TOOL ERROR (exit 2), never a 0%%\n"
        "  --package-set P  passed through to the oracle when its store artifacts\n"
        "                   cannot attribute a component's source\n"
        "  --apply          THE THIN TRIGGER: on `revert-to <v>` ONLY, drive the\n"
        "                   EXISTING `fxstore rollback <v>` (SOFT — content returns\n"
        "                   and the VERSION NUMBER GOES UP; --hard is recovery-only\n"
        "                   and is never used here).  Nothing is mutated for keep\n"
        "                   (a no-op is not an action), withhold, or no-eligible.\n"
        "WHAT IT DECIDES: the candidates are CURRENT and the generation it replaced\n"
        "(the newest version below CURRENT with a different generation genhash that\n"
        "is not a republication of its own predecessor) — the Osier share is a\n"
        "TIE-BREAKER over viable, coherent candidates, not an objective over all of\n"
        "history.\n"
        "exit: 0 = an ACTIONABLE decision (keep | revert-to; with --apply, the\n"
        "      action landed or was refused as a no-op);\n"
        "      1 = NO ELIGIBLE CANDIDATE — a named refusal;\n"
        "      2 = TOOL ERROR (fxstore or the oracle missing/unusable, an unreadable\n"
        "      record, an unparseable objective, this seat's own bad arguments);\n"
        "      3 = WITHHOLD — a verdict the seat will NOT act on (the incumbent\n"
        "      unmeasured, its verdict unknown/mid-boot, or never judged at all),\n"
        "      printed as `withhold`\n"
        "      and NEVER as `revert-to`\n");
}

/* ── ONE predicate: the printed decision and the trigger read the SAME value ── */

enum { DEC_KEEP = 0, DEC_REVERT, DEC_WITHHOLD, DEC_NOELIG };

typedef struct {
    int      kind;
    unsigned v;          /* keep: CURRENT; revert: the winner */
    char     state[96];  /* withhold: the state name ("-" otherwise) */
    char     reason[1400];
} decision_t;

static int dec_exit(const decision_t *d) {
    switch (d->kind) {
    case DEC_KEEP:
    case DEC_REVERT:   return EX_DECISION;
    case DEC_WITHHOLD: return EX_WITHHOLD;
    default:           return EX_NO_ELIGIBLE;
    }
}

/* WHY the winner beat the incumbent — named by the TERM that decided it, so
 * the printed reason is the rule that was applied and not a narrative. */
static void dec_revert_reason(long best, unsigned winner, char *out, size_t cap) {
    long curi = ver_index_of(g_current);
    const char *incumb_share = (curi >= 0 && g_share[curi].measured) ? g_share[curi].share_s : "unmeasured";
    if (curi >= 0 && g_via[curi].state != VIA_OK)
        snprintf(out, cap,
                 "CURRENT v%u is NOT viable (%s), so no share of its can win; the greatest share among the eligible candidates in the bound (rule 1) is %s at v%u",
                 g_current, via_name(g_via[curi].state), g_share[best].share_s, winner);
    else if (curi >= 0 && g_coh.state != COH_CLEAN)
        snprintf(out, cap,
                 "CURRENT v%u DRIFTS (%s), so it is not eligible whatever its share (%s); the greatest share among the eligible candidates in the bound (rule 1) is %s at v%u",
                 g_current, g_coh.reason, incumb_share, g_share[best].share_s, winner);
    else
        snprintf(out, cap,
                 "greater share: v%u holds %s against the incumbent v%u at %s — the change the incumbent replaced is worth keeping, which is the only question the bound asks (rule 1)",
                 winner, g_share[best].share_s, g_current, incumb_share);
}

/* Decides, AND prints the decision/verdict records.  `best` is the winner's
 * index among the eligible candidates, or -1.  The withhold states come FIRST
 * because they are the states in which the rest of the comparison was never
 * made (the incumbent unmeasured) or must not be acted on at all (the
 * incumbent is mid-boot).  `--apply` reads this same struct — there is no
 * second predicate that could drift from it. */
static decision_t decide(long best, unsigned n_eligible, unsigned n_excluded, unsigned n_viable) {
    decision_t d;
    memset(&d, 0, sizeof d);
    long curi = ver_index_of(g_current);

    if (curi >= 0 && !g_share[curi].measured) {
        d.kind = DEC_WITHHOLD;
        snprintf(d.state, sizeof d.state, "current-unmeasured");
        if (n_excluded && n_excluded == g_ncand)
            snprintf(d.reason, sizeof d.reason,
                     "the oracle refused EVERY candidate (%u of %u), including the INCUMBENT v%u — nothing in this comparison was measured, so there is nothing to act on (first refusal: %s)",
                     n_excluded, g_ncand, g_current,
                     g_share[curi].refusal[0] ? g_share[curi].refusal : "(no output)");
        else
            snprintf(d.reason, sizeof d.reason,
                     "the INCUMBENT v%u could not be measured (%s), so the comparison a revert rests on was never made.  A CHALLENGER the oracle refuses blocks nothing — it simply cannot win, and the incumbent stays the only eligible candidate — but an unmeasurable INCUMBENT withholds the decision: the seat will not print `revert-to` for an act it would not take, and a harness must not take it either",
                     g_current, g_share[curi].refusal[0] ? g_share[curi].refusal : "the oracle refused it");
        printf("decision\twithhold\t-\t%s\t%s\tDERIVED\n", d.state, d.reason);
        printf("verdict\twithhold\n");
        h("DECISION: WITHHOLD (%s) — the seat has no actionable answer here: %s", d.state, d.reason);
        return d;
    }

    if (curi >= 0 && g_via[curi].state == VIA_NEVER) {
        /* MEASURED, and the reason this state is here rather than in rule 2:
         * a soft rollback REPUBLISHES the chosen content under a NEW version,
         * and that version has not booted yet - so on the very next run the
         * incumbent's only record is silence, and treating silence as "not
         * viable" made the seat revert back to the generation --apply had
         * just left (a flip-flop on the seat's own act).  A candidate's
         * silence still means not-viable (rule 2); the INCUMBENT's silence
         * withholds, because acting against an incumbent is what the trigger
         * does and the absence of a verdict is not a verdict. */
        d.kind = DEC_WITHHOLD;
        snprintf(d.state, sizeof d.state, "current-not-judged");
        snprintf(d.reason, sizeof d.reason,
                 "the INCUMBENT v%u has NO .bootlog line at all (%s): no boot has judged it yet, so there is no verdict to act against — and a soft rollback republishes its content under a version that has not booted, which is exactly when acting on silence would undo the rollback this seat just made",
                 g_current, g_via[curi].reason);
        printf("decision\twithhold\t-\t%s\t%s\tDERIVED\n", d.state, d.reason);
        printf("verdict\twithhold\n");
        h("DECISION: WITHHOLD (%s) — the incumbent has never been judged: %s", d.state, g_via[curi].reason);
        return d;
    }

    if (curi >= 0 && (g_via[curi].state == VIA_INPROGRESS || g_via[curi].state == VIA_TORN ||
                      g_via[curi].state == VIA_DAMAGED || g_via[curi].state == VIA_UNKNOWN)) {
        d.kind = DEC_WITHHOLD;
        snprintf(d.state, sizeof d.state, "current-verdict-unknown:%s", via_name(g_via[curi].state));
        snprintf(d.reason, sizeof d.reason,
                 "the INCUMBENT v%u has no settled verdict (%s) — %s.  A boot that is in progress, or whose record was torn or damaged, is not something to roll back: the seat withholds instead of recommending the act, and `--apply` mutates nothing",
                 g_current, via_name(g_via[curi].state), g_via[curi].reason);
        printf("decision\twithhold\t-\t%s\t%s\tDERIVED\n", d.state, d.reason);
        printf("verdict\twithhold\n");
        h("DECISION: WITHHOLD (%s) — the incumbent is not in a settled state: %s", d.state, g_via[curi].reason);
        return d;
    }

    if (best < 0) {
        d.kind = DEC_NOELIG;
        snprintf(d.reason, sizeof d.reason,
                 "no candidate is in the bound, viable AND coherent: %u candidate(s) in the bound, %u EXCLUDED by the oracle (named above), %u viable, %u eligible",
                 g_ncand, n_excluded, n_viable, n_eligible);
        printf("decision\tno-eligible-candidate\t-\t-\t%s\tDERIVED\n", d.reason);
        printf("verdict\tno-eligible-candidate\n");
        h("NO ELIGIBLE CANDIDATE — this is a NAMED refusal: the seat will not pick one,");
        h("and it will not 'keep' by default (a keep-by-default would be a decision the");
        h("records do not support). Exit %d. The reasons are on the candidate lines above.", EX_NO_ELIGIBLE);
        return d;
    }

    unsigned winner = g_vers[best].v;
    if (winner == g_current) {
        d.kind = DEC_KEEP;
        d.v = g_current;
        snprintf(d.reason, sizeof d.reason,
                 "CURRENT v%u is in the bound and eligible and holds the greatest share among eligible candidates (%s)",
                 winner, g_share[best].share_s);
        printf("decision\tkeep\t%u\t-\t%s\tDERIVED\n", winner, d.reason);
        printf("verdict\tkeep\n");
        h("DECISION: KEEP v%u — the generation the system is running is the one the order selects.", winner);
        return d;
    }

    d.kind = DEC_REVERT;
    d.v = winner;
    dec_revert_reason(best, winner, d.reason, sizeof d.reason);
    printf("decision\trevert-to\t%u\t-\t%s\tDERIVED\n", winner, d.reason);
    printf("verdict\trevert-to\n");
    h("DECISION: REVERT-TO v%u — %s", winner, d.reason);
    return d;
}

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--store") && i + 1 < argc) g_store = argv[++i];
        else if (!strncmp(argv[i], "--store=", 8)) g_store = argv[i] + 8;
        else if (!strcmp(argv[i], "--rootfs") && i + 1 < argc) g_rootfs = argv[++i];
        else if (!strncmp(argv[i], "--rootfs=", 9)) g_rootfs = argv[i] + 9;
        else if (!strcmp(argv[i], "--fxstore") && i + 1 < argc) g_fxbin = argv[++i];
        else if (!strncmp(argv[i], "--fxstore=", 10)) g_fxbin = argv[i] + 10;
        else if (!strcmp(argv[i], "--oracle") && i + 1 < argc) g_oracle = argv[++i];
        else if (!strncmp(argv[i], "--oracle=", 9)) g_oracle = argv[i] + 9;
        else if (!strcmp(argv[i], "--package-set") && i + 1 < argc) g_pkgset = argv[++i];
        else if (!strncmp(argv[i], "--package-set=", 14)) g_pkgset = argv[i] + 14;
        else if (!strcmp(argv[i], "--apply")) g_apply = 1;
        else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) { usage(stdout); return EX_DECISION; }
        else { fprintf(stderr, "fx-select: unknown arg '%s'\n", argv[i]); usage(stderr); return EX_TOOL_ERROR; }
    }
    if (!g_store) {
        fprintf(stderr, "fx-select: --store is required (the live store is never guessed)\n");
        usage(stderr);
        return EX_TOOL_ERROR;
    }
    check_safe_path(g_store, "--store");
    check_safe_path(g_rootfs, "--rootfs");

    /* THE RULE, printed BEFORE any measurement: a run that dies on a tool
     * error still leaves the order it would have enforced on stdout. */
    h("fx-select — THE SELECTION STEP: which generation SHOULD the system be running?");
    h("The order is LEXICOGRAPHIC and it is ENFORCED, not printed and hoped for:");
    h("  candidates = the incumbent and the change it replaced -> viability (.bootlog)");
    h("  -> coherence (fxstore verify, CURRENT only) -> maximise the Osier share (a TIE-BREAKER)");
    h("A candidate outside the bound, not viable, or CURRENT with drift can NEVER win, whatever its share.");
    h("A state the seat will not act on prints as `withhold`, never as `revert-to`.");
    h("The objective is the oracle's own run_set_share_fraction — never re-derived, never averaged with closure_share_fraction.");
    print_order_table();
    h("");

    resolve_oracle();
    probe_oracle();

    h("# ── the store ─────────────────────────────────────────────────────────");
    read_timeline();

    read_bootlog();
    verify_current();
    compute_bound();

    printf("select\tfx-select/1\tstore\t%s\trootfs\t%s\tfxstore\t%s\toracle\t%s\tversions\t%u\tcurrent\t%u\tapply\t%d\tMEASURED\n",
           g_store, g_rootfs, g_fxbin, g_oracle, g_nvers, g_current, g_apply);
    h("store %s holds %u published version(s); CURRENT (its own [CURRENT] mark) is v%u",
      g_store, g_nvers, g_current);
    {
        char pred[32];
        if (g_pred >= 0) snprintf(pred, sizeof pred, "%u", g_vers[g_pred].v);
        else snprintf(pred, sizeof pred, "-");
        printf("candidate-set\t%d\t%s\t%u\t%s\n", g_current, pred, g_ncand, CANDIDATE_RULE);
    }
    h("THE BOUND: %u candidate(s) — CURRENT v%u and %s", g_ncand, g_current,
      g_pred >= 0 ? "the generation it replaced" : "nothing (no predecessor was identified)");
    if (g_bound_note[0]) { printf("bound-note\t%s\n", g_bound_note); h("BOUND NOTE: %s", g_bound_note); }
    for (unsigned i = 0; i < g_nvers; i++) {
        if (g_candb[i].is_cand) continue;
        printf("not-candidate\t%u\t%s\n", g_vers[i].v, g_candb[i].ncr);
        char cat[96];
        size_t k = 0;
        while (g_candb[i].ncr[k] && g_candb[i].ncr[k] != ':' && k + 1 < sizeof cat) k++;
        memcpy(cat, g_candb[i].ncr, k);
        cat[k] = 0;
        h("not a candidate: v%u — %s (the record carries the reason in full)", g_vers[i].v, cat);
    }
    if (g_gh_err)
        printf("caveat\tgenhash-unreadable\t%u\t%u version(s)' generation fact could not be read (fxstore facts generation exited non-zero): their genhash is treated as ABSENT for the bound\n",
               g_gh_err, g_gh_err);

    /* ── the share: the CANDIDATES only (a version outside the bound cannot
     * win, so measuring it would spend an oracle run on a number nothing
     * reads; its row prints share-state not-measured-outside-the-bound) ── */
    unsigned n_excluded = 0;
    for (unsigned i = 0; i < g_nvers; i++) {
        if (!g_candb[i].is_cand) continue;
        measure_share(g_vers[i].v, &g_share[i]);
        if (!g_share[i].measured) n_excluded++;
    }

    /* ── the frozen candidate table, and the order ENFORCED ────────────── */
    long best = -1;
    unsigned n_eligible = 0, n_viable = 0;
    h("");
    h("# ── the candidates — frozen tag `candidate`; columns, in this order:");
    h("#    version, is-current, \"viability\", state, \"viability-reason\", reason,");
    h("#    \"share\", value, \"share-state\", measured|oracle-refused|not-measured-outside-the-bound,");
    h("#    \"share-bytes\", osier/total, \"coherence\", state, \"coherence-reason\", reason,");
    h("#    \"eligible\", yes|no, mark, \"is-candidate\", yes|no, \"genhash\", gh ──");
    for (unsigned i = 0; i < g_nvers; i++) {
        via_t *t = &g_via[i];
        share_t *s = &g_share[i];
        candb_t *c = &g_candb[i];
        int viable = (t->state == VIA_OK);
        int is_cur = g_vers[i].is_current;
        int coherent;
        const char *coh_state, *coh_reason;
        char cohbuf[640];
        if (is_cur) {
            coherent = (g_coh.state == COH_CLEAN);
            coh_state = (g_coh.state == COH_CLEAN) ? "clean" : "drift";
            coh_reason = g_coh.reason;
        } else {
            coherent = 1; /* not-live is NOT a disqualifier */
            coh_state = "not-live";
            snprintf(cohbuf, sizeof cohbuf,
                     "not the live generation (CURRENT is v%u): the live rootfs corresponds to the CURRENT generation alone, so NO verification was run for v%u and none is claimed",
                     g_current, g_vers[i].v);
            coh_reason = cohbuf;
        }
        int eligible = c->is_cand && viable && coherent && s->measured;
        if (viable) n_viable++;
        if (eligible) {
            n_eligible++;
            /* a TIE GOES TO THE INCUMBENT: a tie must NEVER cause a revert */
            if (best < 0 || (s->share > g_share[best].share) || (s->share == g_share[best].share && g_vers[i].is_current))
                best = (long)i;
        }
        const char *share_state = c->is_cand
                                ? (s->measured ? "measured" : "oracle-refused")
                                : "not-measured-outside-the-bound";
        const char *mark;
        char markbuf[128];
        if (!c->is_cand) {
            mark = "DERIVED-not-candidate";
        } else if (!s->measured) {
            snprintf(markbuf, sizeof markbuf, "ABSENT-share-oracle-refused");
            mark = markbuf;
        } else if (t->state == VIA_NEVER || t->state == VIA_TORN || t->state == VIA_DAMAGED) {
            snprintf(markbuf, sizeof markbuf, "ABSENT-viability-%s", via_name(t->state));
            mark = markbuf;
        } else {
            mark = "MEASURED";
        }
        printf("candidate\t%u\t%d\tviability\t%s\tviability-reason\t%s\tshare\t%s\tshare-state\t%s\tshare-bytes\t%s\tcoherence\t%s\tcoherence-reason\t%s\teligible\t%s\t%s\tis-candidate\t%s\tgenhash\t%s\n",
               g_vers[i].v, is_cur, via_name(t->state), t->reason,
               s->measured ? s->share_s : "-", share_state,
               s->measured && s->bytes[0] ? s->bytes : "-",
               coh_state, coh_reason, eligible ? "yes" : "no", mark,
               c->is_cand ? "yes" : "no",
               g_gh[i].present ? g_gh[i].gh
                               : (g_gh[i].read ? "none"
                                               : "not-read-the-walk-stopped-above-it"));
        if (c->is_cand && !s->measured)
            printf("excluded\t%u\toracle-refused\texit=%d\t%s\tMEASURED\n", g_vers[i].v, s->rc,
                   s->refusal[0] ? s->refusal : "(the oracle printed nothing)");
        h("v%u%s viable=%s (%s) share=%s coherence=%s eligible=%s candidate=%s",
          g_vers[i].v, is_cur ? " [CURRENT]" : "",
          viable ? "yes" : "no", via_name(t->state),
          s->measured ? s->share_s : (c->is_cand ? "UNMEASURED" : "not measured (outside the bound)"),
          coh_state, eligible ? "yes" : "no", c->is_cand ? "yes" : "no");
    }

    if (n_excluded)
        printf("caveat\texcluded-candidates\t%u\t%u of the %u CANDIDATE(s) were EXCLUDED BY NAME above (the oracle refused them): they are NOT counted as 0%% and they were not ranked\n",
               n_excluded, n_excluded, g_ncand);
    if (g_coh.state == COH_DRIFT)
        printf("drift\t%u\t%u\t%s\tMEASURED\n", g_current, g_coh.n_drift, g_coh.reason);

    /* ── the decision (ONE predicate; --apply below reads the same value) ── */
    h("");
    decision_t dec = decide(best, n_eligible, n_excluded, n_viable);

    if (!g_apply) {
        h("(read-only run: no mutation was made.  --apply is the thin trigger, and it acts");
        h(" only on an actionable `revert-to` decision, by the SOFT `fxstore rollback`.)");
        return dec_exit(&dec);
    }

    /* ── PART B: the thin trigger — the SAME decision value, no second rule ── */
    if (dec.kind == DEC_KEEP) {
        printf("apply\trefused\tcurrent-already-the-winner\tno rollback issued; the store is byte-unchanged\tMEASURED\n");
        h("APPLY REFUSED: CURRENT v%u IS already the winner — a no-op must never be dressed as an action.", dec.v);
        return dec_exit(&dec);
    }
    if (dec.kind == DEC_WITHHOLD) {
        printf("apply\trefused\twithheld-%s\tno rollback issued; the store is byte-unchanged\tMEASURED\n", dec.state);
        h("APPLY REFUSED: the decision is WITHHOLD (%s) — the seat does not act on its own non-actionable verdict.", dec.state);
        return dec_exit(&dec);
    }
    if (dec.kind != DEC_REVERT) {   /* DEC_NOELIG already refused above */
        h("APPLY REFUSED: the decision names no winner to revert to.");
        return dec_exit(&dec);
    }

    unsigned before = g_current, target = dec.v;
    printf("apply-path\tfxstore-rollback-soft\t%s\n",
           "SOFT (no --hard): content returns and the VERSION NUMBER GOES UP - the substrate's own roll-forward semantics (README.md:136-138), which keeps the timeline append-only and the boot history honest; --hard is recovery-only (repoints CURRENT with no new version and renumbers away the versions in between)");
    char *cmd;
    if (asprintf(&cmd, "'%s' rollback %u --store '%s' 2>&1", g_fxbin, target, g_store) < 0)
        die("out of memory");
    int rc;
    char *out = run_capture(cmd, &rc);
    free(cmd);
    printf("apply\tattempted\trevert-to\t%u\t%s\n", target,
           "fxstore rollback (SOFT), the only decision value this trigger acts on");
    if (rc != 0) {
        char m[512];
        first_line(out, m, sizeof m);
        free(out);
        printf("apply\tfailed\texit=%d\t%s\tMEASURED\n", rc, m[0] ? m : "(no output)");
        h("APPLY FAILED (exit %d): the rollback to v%u did NOT land — the store is UNCHANGED.", rc, target);
        h("No SELECT line is printed for a failed attempt: a SELECT record must never read as an action taken.");
        return EX_TOOL_ERROR;
    }
    free(out);
    /* the SELECT record is printed ONLY once the rollback has landed (an
     * attempt that failed must not leave a record that reads as an act), and
     * it carries the outcome the seat claims to rely on */
    g_nvers = 0;
    read_timeline();
    printf("SELECT\t%s\t%u\t%u\t%u\tversion-increased\t%s\tfxstore rollback (SOFT); the decision was revert-to %u and the incumbent was not the winner\n",
           g_store, before, target, g_current, (g_current > before) ? "yes" : "no", target);
    h("SELECT: %s CURRENT v%u -> v%u by `fxstore rollback %u` (SOFT) — it landed; the new CURRENT is v%u. Cause: %s",
      g_store, before, target, target, g_current, dec.reason);
    printf("apply\tdone\tsoft-rollback\tfrom\t%u\tto\t%u\tnew-current\t%u\tversion-increased\t%s\tMEASURED\n",
           before, target, g_current, (g_current > before) ? "yes" : "no");
    if (g_current <= before) {
        h("FINDING: the soft rollback did NOT raise the version number (v%u -> v%u), which contradicts");
        h(" the semantics this seat relies on (the substrate's roll-forward). Report it: the claim is false.");
        return EX_TOOL_ERROR;
    }
    h("APPLY DONE: content moved back to v%u's generation and the timeline stayed append-only.", target);
    return dec_exit(&dec);
}
