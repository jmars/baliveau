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
 *   1. CANDIDATES  every published snapshot version `fxstore timeline`
 *                  lists; CURRENT comes from that listing's own
 *                  [CURRENT] mark (the same source the oracle resolves
 *                  from — never a second resolution).
 *   2. VIABILITY   from <store>/.bootlog ONLY: the LAST non-shutdown line
 *                  naming the version.  ok -> viable.  failed -> not.
 *                  in-progress -> not (no verdict was reached; fx-init's
 *                  own roll-forward treats it as a failure).  no line ->
 *                  not, reason `never-judged`.  An unterminated (TORN)
 *                  last line whose first token is the version -> not,
 *                  reason `torn-verdict-unknown`: the file was mid-write
 *                  ABOUT that version, so its silence is a hole, not a
 *                  judgement — prefer the false stop (the settled rule,
 *                  src/agent/outcome.c:1032-1035 and the RUN-style
 *                  judgement it poisons; tests/test_outcome.sh phase 11).
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
 *   5. ELIGIBLE    viable AND (coherent, if it is CURRENT).  `not-live`
 *                  is not a disqualifier; drift is.
 *   6. WINNER      the eligible candidate with the GREATEST share.  TIE ->
 *                  the HIGHEST version, so in a normal timeline (CURRENT
 *                  is the newest) a tie NEVER causes a revert.
 *   7. DECISION    `keep <CURRENT>` if the winner is CURRENT, else
 *                  `revert-to <winner>`; NO eligible candidate -> a NAMED
 *                  loud state and a NON-ZERO exit (1) — never a silent
 *                  pick, and never "keep" by default.
 *   8. EXCLUDED    a candidate the oracle refuses is excluded and NAMED,
 *                  and the count prints as its own caveat line.
 *
 * ── WHAT IT READS, and nothing else ────────────────────────────────────
 *   `fxstore timeline --store S`      candidates + CURRENT (REUSED)
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
 *   (b) tools/fx-audit.c read_bootlog + bootlog_last_verdict (:658) — the
 *       right per-version semantics (LAST non-shutdown line wins), but
 *       embedded in a VALIDATED main program with file-static storage; a
 *       host tool cannot link it without splitting that seat, and fx-audit.c
 *       is not in this unit's write scope.
 *   (c) tools/fx-report.c read_bootlog — per-boot EVENT rows for the
 *       report; it has no per-version eligibility rule at all.
 * So this file MIRRORS (b)'s per-version rule (last non-shutdown line
 * wins) and adds two things this seat needs and neither (b) nor (c) has: a
 * 4-field writer shape with a NAMED damaged-line count, and the torn-tail
 * poison in the strictly more conservative form the order specifies (a torn
 * tail naming the version poisons it EVEN IF an earlier complete verdict
 * exists — see the ORDER table step 2 for why this is stated, not hidden).
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
 * It REFUSES loudly and mutates NOTHING when the decision is `keep`
 * (CURRENT is already the winner — a no-op must never be dressed as an
 * action; exit 0, the decision stands) and when no candidate is eligible
 * (the run has already refused with exit 1).  It also refuses to act when
 * the INCUMBENT could not be measured (CURRENT excluded by the oracle):
 * acting on an unmeasured incumbent is acting on half the comparison, so
 * that is a tool error (exit 2), no mutation, named.
 *
 * ── OUTPUT, and EXIT CODES ─────────────────────────────────────────────
 * Frozen tab-separated machine records, one frozen tag per line, column
 * order per tag never changing, with a `#` human summary BESIDE them (the
 * house style of tools/fx-report.c).  THE ORDER table and these BOUNDS are
 * part of the output, printed on every run.  Every line is marked MEASURED
 * / DERIVED / ABSENT with the absence's KIND stated.  BYTE-DETERMINISTIC:
 * no wall-clock, no locale, no randomness, no HEAD — two runs over the same
 * store are `cmp`-identical (gated).
 *   0 = a decision was produced (`keep` or `revert-to`; with --apply, the
 *       action landed — or was refused because it was a no-op);
 *   1 = NO ELIGIBLE CANDIDATE — a NAMED refusal, never a silent pick;
 *   2 = TOOL ERROR (fxstore or the oracle missing/unusable, an unreadable
 *       record, an unparseable objective, this seat's own bad arguments).
 * (fx-audit.c's 0 = coherent / 1 = incoherent / 2 = tool error is the
 * model; this seat's three states differ and are stated here and in usage.)
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
 { 1, "candidates", "fxstore timeline --store <store>",
   "every published snapshot version is a candidate; CURRENT is read from the SAME listing's [CURRENT] mark (the oracle's own resolution, never a second one)" },
 { 2, "viability", "<store>/.bootlog",
   "the LAST non-shutdown line naming the version: ok=viable; failed|in-progress|damaged=NOT viable (reason named); no line=NOT viable (never-judged); an unterminated (torn) last line whose first token is that version poisons it (verdict unknown - the file was mid-write ABOUT it): prefer the false stop (outcome.c:1032-1035, test_outcome.sh phase 11)" },
 { 3, "share", "fx-osier-share --store <store> --as-of <v>",
   "run_set_share_fraction is THE OBJECTIVE - the oracle's own number, never re-derived here; closure_share_fraction is NEVER read (comparison only, never averaged in, never substituted); a candidate the oracle REFUSES is excluded BY NAME, never counted as 0%" },
 { 4, "coherence", "fxstore verify <rootfs> --as-of <CURRENT> --store <store>",
   "exit 0 = no drift = coherent; judged FOR CURRENT ONLY, because the live rootfs corresponds to the CURRENT generation alone - every other candidate is not-live (NON-disqualifying) and this seat never claims to have verified a generation it did not materialize" },
 { 5, "eligibility", "viable AND (coherent if CURRENT)",
   "a candidate that is not viable, or is CURRENT with drift, can NEVER win, whatever its share - the order is ENFORCED, not printed and hoped for" },
 { 6, "winner", "greatest share among ELIGIBLE candidates",
   "tie -> the HIGHEST version, so in a normal timeline (CURRENT is the newest) a tie NEVER causes a revert; the tie is gated, not assumed" },
 { 7, "decision", "keep <CURRENT> if the winner is CURRENT, else revert-to <winner>",
   "NO eligible candidate -> a NAMED refusal and exit 1: never a silent pick, never keep-by-default" },
 { 8, "apply", "--apply -> fxstore rollback <winner> --store <store> (SOFT: no --hard)",
   "SOFT because the content returns and the VERSION NUMBER GOES UP - the substrate's own roll-forward semantics, keeping the timeline append-only and the boot history honest; --hard is recovery-only (repoints CURRENT with no new version and renumbers away the versions in between). Refuses with exit 0 and NO mutation when CURRENT is already the winner (a no-op is not an action)" },
};

static const struct { const char *id, *text; } BOUNDS[] = {
 { "coherence-not-live",
   "every non-CURRENT candidate's coherence is not-live: this seat measured ONE rootfs, the live one, and reports not-live for the rest rather than implying a verification it did not run" },
 { "share-of-a-partial-snapshot",
   "an activation can publish an INTERMEDIATE snapshot whose run set is still empty; the oracle measures it as run_set_share_fraction 0/0 = 0.000000 and this seat reports THAT number - it never re-derives a 'real' one from the finished snapshot (ONE measurement, ONE implementation)" },
 { "bootlog-is-in-guest-writable",
   "root in-guest can forge or truncate .bootlog exactly as it can .recovery: this seat's viability term is a function of a record the suspect can edit. Catching that is the AUDIT seat's previous-observation comparison, not this seat's job" },
 { "incumbent-unmeasured",
   "when the oracle refuses for CURRENT its share is unknown; the candidate is excluded BY NAME and a `revert-to` is still the rule's answer over the candidates that WERE measured - and --apply REFUSES to act on it (exit 2), because acting on an unmeasured incumbent is acting on half the comparison" },
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
       VIA_NEVER, VIA_TORN };

static const char *via_name(int s) {
    switch (s) {
    case VIA_OK:          return "ok";
    case VIA_FAILED:      return "failed";
    case VIA_INPROGRESS:  return "in-progress";
    case VIA_UNKNOWN:     return "unknown-verdict";
    case VIA_NEVER:       return "never-judged";
    case VIA_TORN:        return "torn-verdict-unknown";
    default:              return "never-judged";
    }
}

typedef struct {
    int      state;              /* VIA_* */
    char     reason[320];        /* the line it came from, or the absence's kind */
    unsigned line;               /* .bootlog line number, 0 when no line */
} via_t;

static via_t g_via[MAX_VERSIONS];

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
            /* terminated but not the writer's shape: damaged, named by count,
             * NEVER read as a verdict (outcome.c:517-522's rule) */
            damaged++;
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
 * answers `--help` yet refuses every candidate is caught by the
 * every-candidate-refused guard at the end of the sweep. */
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
    char     reason[640];
    unsigned n_drift;
} coh_t;

static coh_t g_coh = { 0, COH_NOTLIVE, "", 0 };

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
    unsigned n = 0;
    char first_drift[512] = "";
    char *save = NULL;
    for (char *t = strtok_r(out, "\n", &save); t; t = strtok_r(NULL, "\n", &save)) {
        if (strncmp(t, "fxstore: verify ", 16) == 0) {
            const char *p = strstr(t, ": ");
            if (p) {
                unsigned long k = 0;
                if (sscanf(p + 2, "%lu", &k) == 1) n = (unsigned)k;
            }
            continue;
        }
        if (!first_drift[0]) snprintf(first_drift, sizeof first_drift, "%s", t);
        if (!n) n++;
    }
    free(out);
    g_coh.state = COH_DRIFT;
    g_coh.n_drift = n;
    snprintf(g_coh.reason, sizeof g_coh.reason,
             "fxstore verify '%s' --as-of v%u exited 1: %u drift(s) against the install facts, first: %s",
             g_rootfs, g_current, n, first_drift[0] ? first_drift : "(no drift line)");
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
        "                   only (default %s, fxstore verify's own default)\n"
        "  --fxstore BIN    fxstore binary (default $FXSTORE_BIN, else PATH); also\n"
        "                   handed to the oracle as FXSTORE_BIN so the two agree\n"
        "  --oracle BIN     the objective's binary (default $FX_OSIER_SHARE_BIN,\n"
        "                   else fx-osier-share); PROBED, and a missing one is a\n"
        "                   TOOL ERROR (exit 2), never a 0%%\n"
        "  --package-set P  passed through to the oracle when its store artifacts\n"
        "                   cannot attribute a component's source (the oracle's own\n"
        "                   --package-set)\n"
        "  --apply          THE THIN TRIGGER: on `revert-to <v>` only, drive the\n"
        "                   EXISTING `fxstore rollback <v>` (SOFT — content returns\n"
        "                   and the VERSION NUMBER GOES UP; --hard is recovery-only\n"
        "                   and is never used here).  No mutation when CURRENT is\n"
        "                   already the winner (a no-op is not an action) and never\n"
        "                   when no candidate is eligible.\n"
        "exit: %d = a decision was produced; %d = NO ELIGIBLE CANDIDATE (named\n"
        "      refusal); %d = tool error (fxstore/the oracle missing or unusable,\n"
        "      an unreadable record, an unparseable objective, bad arguments)\n",
        "/", EX_DECISION, EX_NO_ELIGIBLE, EX_TOOL_ERROR);
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
    h("  viability (.bootlog) -> coherence (fxstore verify, CURRENT only) -> maximise the Osier share");
    h("A candidate that is not viable, or is CURRENT with drift, can NEVER win, whatever its share.");
    h("The objective is the oracle's own run_set_share_fraction — never re-derived, never averaged with closure_share_fraction.");
    print_order_table();
    h("");

    resolve_oracle();
    probe_oracle();

    h("# ── the store ─────────────────────────────────────────────────────────");
    read_timeline();
    printf("select\tfx-select/1\tstore\t%s\trootfs\t%s\tfxstore\t%s\toracle\t%s\tversions\t%u\tcurrent\t%u\tapply\t%d\tMEASURED\n",
           g_store, g_rootfs, g_fxbin, g_oracle, g_nvers, g_current, g_apply);
    h("store %s holds %u published version(s); CURRENT (its own [CURRENT] mark) is v%u",
      g_store, g_nvers, g_current);

    read_bootlog();
    verify_current();

    unsigned n_excluded = 0;
    for (unsigned i = 0; i < g_nvers; i++) {
        measure_share(g_vers[i].v, &g_share[i]);
        if (!g_share[i].measured) n_excluded++;
    }
    /* an oracle that measured NOTHING on a store with versions has not told
     * us "the candidates are bad" — it has told us it cannot measure, which
     * is a TOOL ERROR, not an empty eligibility set */
    if (g_nvers && n_excluded == g_nvers)
        die("the oracle refused EVERY one of the %u candidate(s) — that is an unusable oracle, not an empty field of eligible candidates (first refusal: %s)",
            g_nvers, g_share[0].refusal[0] ? g_share[0].refusal : "(no output)");

    /* ── the frozen candidate table, and the order ENFORCED ────────────── */
    long best = -1;
    unsigned n_eligible = 0, n_viable = 0;
    h("");
    h("# ── the candidates — frozen tag `candidate`; columns, in this order:");
    h("#    version, is-current, \"viability\", state, \"viability-reason\", reason,");
    h("#    \"share\", value, \"share-state\", measured|oracle-refused, \"share-bytes\", osier/total,");
    h("#    \"coherence\", state, \"coherence-reason\", reason, \"eligible\", yes|no, mark ──");
    for (unsigned i = 0; i < g_nvers; i++) {
        via_t *t = &g_via[i];
        share_t *s = &g_share[i];
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
        int eligible = viable && coherent && s->measured;
        if (viable) n_viable++;
        if (eligible) {
            n_eligible++;
            if (best < 0 || s->share > g_share[best].share ||
                (s->share == g_share[best].share && g_vers[i].v > g_vers[best].v))
                best = (long)i;
        }
        const char *mark;
        char markbuf[128];
        if (!s->measured) {
            snprintf(markbuf, sizeof markbuf, "ABSENT-share-oracle-refused");
            mark = markbuf;
        } else if (t->state == VIA_NEVER || t->state == VIA_TORN) {
            snprintf(markbuf, sizeof markbuf, "ABSENT-viability-%s", via_name(t->state));
            mark = markbuf;
        } else {
            mark = "MEASURED";
        }
        printf("candidate\t%u\t%d\tviability\t%s\tviability-reason\t%s\tshare\t%s\tshare-state\t%s\tshare-bytes\t%s\tcoherence\t%s\tcoherence-reason\t%s\teligible\t%s\t%s\n",
               g_vers[i].v, is_cur, via_name(t->state), t->reason,
               s->measured ? s->share_s : "-",
               s->measured ? "measured" : "oracle-refused",
               s->measured && s->bytes[0] ? s->bytes : "-",
               coh_state, coh_reason, eligible ? "yes" : "no", mark);
        if (!s->measured)
            printf("excluded\t%u\toracle-refused\texit=%d\t%s\tMEASURED\n", g_vers[i].v, s->rc,
                   s->refusal[0] ? s->refusal : "(the oracle printed nothing)");
        h("v%u%s viable=%s (%s) share=%s coherence=%s eligible=%s",
          g_vers[i].v, is_cur ? " [CURRENT]" : "",
          viable ? "yes" : "no", via_name(t->state),
          s->measured ? s->share_s : "UNMEASURED", coh_state,
          eligible ? "yes" : "no");
    }

    if (n_excluded)
        printf("caveat\texcluded-candidates\t%u\t%u of %u candidate(s) were EXCLUDED BY NAME above (the oracle refused them): they are NOT counted as 0%% and they were not ranked\n",
               n_excluded, n_excluded, g_nvers);
    if (g_coh.state == COH_DRIFT)
        printf("drift\t%u\t%u\t%s\tMEASURED\n", g_current, g_coh.n_drift,
               g_coh.reason);

    /* ── the decision ──────────────────────────────────────────────────── */
    h("");
    if (best < 0) {
        printf("decision\tno-eligible-candidate\t-\tno candidate is viable AND coherent: %u candidate(s) judged, %u EXCLUDED by the oracle (named above), %u viable, %u eligible\tDERIVED\n",
               g_nvers, n_excluded, n_viable, n_eligible);
        printf("verdict\tno-eligible-candidate\n");
        h("NO ELIGIBLE CANDIDATE — this is a NAMED refusal: the seat will not pick one,");
        h("and it will not 'keep' by default (a keep-by-default would be a decision the");
        h("records do not support). Exit %d. The reasons are on the candidate lines above.", EX_NO_ELIGIBLE);
        return EX_NO_ELIGIBLE;
    }

    unsigned winner = g_vers[best].v;
    if (winner == g_current) {
        printf("decision\tkeep\t%u\tCURRENT v%u is eligible and holds the greatest share among eligible candidates (%s)\tDERIVED\n",
               winner, winner, g_share[best].share_s);
        printf("verdict\tkeep\n");
        h("DECISION: KEEP v%u — the generation the system is running is the one the order selects.", winner);
        if (g_apply) {
            printf("apply\trefused\tcurrent-already-the-winner\tno rollback issued; the store is byte-unchanged\tMEASURED\n");
            h("APPLY REFUSED: CURRENT v%u IS already the winner — a no-op must never be dressed as an action.", winner);
        }
        return EX_DECISION;
    }

    /* revert-to: name WHICH term of the order produced it */
    char reason[1024];
    long curi = ver_index_of(g_current);
    if (curi >= 0 && !g_share[curi].measured)
        snprintf(reason, sizeof reason,
                 "CURRENT v%u could not be measured (the oracle refused it, see excluded above), and the greatest share among the candidates that WERE measured and eligible is %s at v%u",
                 g_current, g_share[best].share_s, winner);
    else if (curi >= 0 && !(g_via[curi].state == VIA_OK))
        snprintf(reason, sizeof reason,
                 "CURRENT v%u is NOT viable (%s), so no share of its can win; the greatest share among eligible candidates is %s at v%u",
                 g_current, via_name(g_via[curi].state), g_share[best].share_s, winner);
    else if (curi >= 0 && g_coh.state != COH_CLEAN)
        snprintf(reason, sizeof reason,
                 "CURRENT v%u DRIFTS (%s), so it is not eligible whatever its share (%s); the greatest share among eligible candidates is %s at v%u",
                 g_current, g_coh.reason, g_share[curi].measured ? g_share[curi].share_s : "unmeasured",
                 g_share[best].share_s, winner);
    else
        snprintf(reason, sizeof reason,
                 "greater share: v%u holds %s against CURRENT v%u at %s",
                 winner, g_share[best].share_s, g_current,
                 (curi >= 0 && g_share[curi].measured) ? g_share[curi].share_s : "unmeasured");
    printf("decision\trevert-to\t%u\t%s\tDERIVED\n", winner, reason);
    printf("verdict\trevert-to\n");
    h("DECISION: REVERT-TO v%u — %s", winner, reason);

    if (!g_apply) {
        h("(read-only run: no mutation was made.  --apply is the thin trigger, and it acts");
        h(" only on this decision, by the SOFT `fxstore rollback` — see bound/apply-path.)");
        return EX_DECISION;
    }

    /* ── PART B: the thin trigger (SOFT rollback, never --hard) ────────── */
    printf("apply-path\tfxstore-rollback-soft\t%s\n",
           "SOFT (no --hard): content returns and the VERSION NUMBER GOES UP - the substrate's own roll-forward semantics (README.md:136-138), which keeps the timeline append-only and the boot history honest; --hard is recovery-only (repoints CURRENT with no new version and renumbers away the versions in between)");
    if (curi >= 0 && !g_share[curi].measured) {
        printf("apply\trefused\tcurrent-share-not-measured\tno rollback issued; the store is byte-unchanged\tMEASURED\n");
        h("APPLY REFUSED: the incumbent v%u could not be measured (the oracle refused it), and acting on");
        h("an unmeasured incumbent is acting on half the comparison. Exit %d, NO mutation.", g_current, EX_TOOL_ERROR);
        return EX_TOOL_ERROR;
    }
    char *cmd;
    if (asprintf(&cmd, "'%s' rollback %u --store '%s' 2>&1", g_fxbin, winner, g_store) < 0)
        die("out of memory");
    int rc;
    char *out = run_capture(cmd, &rc);
    free(cmd);
    printf("SELECT\t%s\t%u\t%u\t%s\n", g_store, g_current, winner,
           "fxstore rollback (SOFT), because the decision is revert-to and CURRENT is not the winner");
    h("SELECT: %s CURRENT v%u -> v%u by `fxstore rollback %u` (SOFT) — %s",
      g_store, g_current, winner, winner, reason);
    if (rc != 0) {
        char m[512]; first_line(out, m, sizeof m);
        free(out);
        printf("apply\tfailed\texit=%d\t%s\tMEASURED\n", rc, m[0] ? m : "(no output)");
        h("APPLY FAILED (exit %d): the rollback to v%u did not land — the store is UNCHANGED.", rc, winner);
        return EX_TOOL_ERROR;
    }
    free(out);
    /* prove the claimed semantics: read CURRENT back from the timeline */
    unsigned before = g_current;
    g_nvers = 0;
    read_timeline();
    printf("apply\tdone\tsoft-rollback\tfrom\t%u\tto\t%u\tnew-current\t%u\tversion-increased\t%s\tMEASURED\n",
           before, winner, g_current, (g_current > before) ? "yes" : "no");
    h("APPLY DONE: CURRENT is now v%u (was v%u). The soft path published a NEW version number —", g_current, before);
    h(" the content moved back while the timeline stayed append-only. Exit 0.", EX_DECISION);
    if (g_current <= before) {
        h("FINDING: the soft rollback did NOT raise the version number (v%u -> v%u), which contradicts");
        h(" the semantics this seat relies on (the substrate's roll-forward). Report it: the claim is false.");
        return EX_TOOL_ERROR;
    }
    return EX_DECISION;
}
