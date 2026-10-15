/* tools/fx-report.c — the REPORTER SEAT of the baliveau harness.
 *
 * SIBLING OF THE ORACLE (tools/fx-osier-share.c) and the AUDIT
 * (tools/fx-audit.c), and it inherits the family's three properties
 * (design record §7.1): HOST-SIDE, AGENT-UNWRITABLE, and a function of
 * OBSERVABLE SYSTEM STATE.  Where the oracle asks *is it better?* and the
 * audit asks *is it honest?*, this seat asks *is it documented?* — §1a's
 * second goal: observability sufficient for a SEPARATE tool to generate
 * EU AI Act reports.  It therefore does not write the reports; it emits
 * the account another tool would read, and the account's SHAPE is frozen:
 *
 *   - MACHINE-READABLE BY CONSTRUCTION.  Every non-`#` line is a
 *     tab-separated record whose first field is a frozen tag and whose
 *     column order per tag never changes (`taxonomy` and `retention`
 *     below are part of the OUTPUT, printed on every run, so a consumer
 *     can discover the grammar from the report itself).  `#` lines are
 *     the human summary — beside the records, never instead of them.
 *   - DETERMINISTIC.  No wall-clock, no locale, no randomness, no HEAD:
 *     the output is a function of the store's bytes and the fxstore
 *     binary's facts dump alone.  Two runs over the same store are
 *     byte-identical (gated in tests/test_fx_report.sh).
 *   - EVERY LINE IS MARKED for what it is: MEASURED (read from a record),
 *     DERIVED (computed from records — the computation stated), or ABSENT
 *     (and WHICH kind of absence: "there were none" vs "this is not
 *     recorded" — the distinction §1a gap 3 exists to keep).
 *
 * WHAT IT READS — the store's DURABLE records, and nothing else:
 *   <store>/.db/snapshots/CURRENT     fxstore:   the current version
 *   `fxstore timeline`                fxstore:   the published versions
 *   `fxstore facts <rel> --as-of N`   the version-bound facts per version
 *                                     (the seat that exists for exactly
 *                                     this; REUSED, never reimplemented)
 *   <store>/.bootlog                  fx-init, per boot:
 *                                     "<v> <status> <epoch> <nonce>\n"
 *                                     (bootlog_append's "%u %s %u %s")
 *   <store>/.recovery                 fx-init, per AUTOMATIC roll-forward:
 *                                     "#"-header + "<epoch> <published>
 *                                     <from-failed> <genhash|-> <nonce>"
 *   <store>/.operator                 fx-init, per OPERATOR intervention on
 *                                     the generation plane (fx-init ca9cb06,
 *                                     and since the RUNTIME-RECORD closure
 *                                     also fx-activate ITSELF for a publish
 *                                     committed OUTSIDE the control handler
 *                                     — a direct exec — on a boot carrying
 *                                     an fx.bootnonce=):
 *                                     "#"-header + "<epoch> <action> <arg>
 *                                     <outcome> <from-version|-> <to-version|->
 *                                     <boot-nonce|none>" — INCLUDING the ones
 *                                     that failed or were refused (the ctrl
 *                                     arms, init.zig:3556/:3665/:3705/:3730/
 *                                     :3795/:3808/:3828/:3837/:3856/:3899).
 *                                     The header IN THE FILE is the
 *                                     definition (OPERATOR_HEADER,
 *                                     operator_journal.zig:122 — ONE
 *                                     definition, imported by both writers)
 *                                     — read from the artifact, not assumed
 *                                     here.
 *   <store>/<genhash>-system-generation/config.dhall
 *                                     fx-activate, per activation: the
 *                                     RETAINED INPUT (fx-init 1399dbd),
 *                                     named by the generation_config fact
 *                                     (genhash, config_sha256, origin —
 *                                     origin store-relative).  The claim
 *                                     unit's two extraEtc rows ride INTO
 *                                     that dir: etc/fx-claim.tsv + .le (the
 *                                     claim BYTES; RETAINED-WHILE-NAMED)
 *   <store>.fx-claim-obs              fx-claim, the claim unit's judge seat
 *                                     (S1): the host-side VERDICT record —
 *                                     format-1 observation, ONE writer, the
 *                                     format header in the file IS the
 *                                     definition: "fx-claim-observation 1" /
 *                                     "store <abs>" / "claim <genhash>
 *                                     version <N> verdict <cls> claim-sha
 *                                     <sha|-> op-from <v|->" / "end".  This
 *                                     is the claim class's record (S2); the
 *                                     reporter relies on it and derives
 *                                     nothing about justification
 *
 * IT NEVER OPENS attempts.jsonl OR ANY OTHER HARNESS SELF-REPORT, and it
 * never consults the runtime datalog (see the rt-log bound below).
 *
 * ── the event taxonomy (FROZEN — one table in this file, printed on
 *    every run as `taxonomy` records; the deliverable as much as the
 *    output is) ─────────────────────────────────────────────────────────
 * For every event class the report can emit: the RECORD it is read from,
 * and what an ABSENCE of the class means — "none occurred" vs "this is
 * not durably recorded".  A reader must be able to tell "there were no
 * failed boots" from "failed boots are not something these records can
 * show"; where the records cannot make that distinction, the table says
 * so instead of the output implying more than it knows.
 *
 * ── what this seat CANNOT read, measured and stated, not discovered
 *    later ──────────────────────────────────────────────────────────────
 * fx-init's runtime datalog — rt_effect/rt_control: activations
 * (rt_effect "version"), REFUSED activations (rt_effect "activate",
 * "failed", init.zig:3667; "dhake-failed", :3818), rollbacks and
 * shutdowns (rt_control, the shared activate|rollback ctrl arm, :3558) —
 * lives at /run/fx/log.db (DEFAULT_RUN "/run/fx", init.zig:33; path
 * built :4856, opened :4857).  Post-pivot "/" is TMPFS (init.zig's M4
 * pivot: /proc/mounts' root entry reads "tmpfs" after it), so the log
 * DOES NOT SURVIVE A REBOOT, and this seat never reads it.
 *
 * THE OPERATOR PLANE IS DURABLE NOW, and this seat reads it.  fx-init
 * ca9cb06 added <store>/.operator: one row per control-channel
 * intervention on the generation plane, INCLUDING the ones that FAILED
 * or were REFUSED, appended and fsync'd BEFORE the reply is flushed.  So
 * `operator-intervention` is MEASURED from those rows, and
 * `activation-refusal` — whose absence-meaning was NOT-DURABLY-RECORDED,
 * because fx-activate refuses before touching the store and the only
 * record of it lived in tmpfs — is MEASURED too.
 *
 * THE SECOND WRITER (the runtime-record closure) NARROWED the
 * "only writer" claim without weakening it into vagueness: a boot process
 * that executes fx-activate OUTSIDE PID1's control handler (the harness's
 * channel-less direct-exec fallback, a command in the interactive shell)
 * used to publish a generation with NO durable operator record at all —
 * the gap this closure closes.  fx-activate now records that publish
 * ITSELF, in the SAME grammar and the SAME file (operator_journal.zig is
 * the one definition of both), under two structural conditions: the
 * handler's own child carries a marker telling it the handler is about to
 * append the row for the REQUEST (so a channel activation still leaves
 * EXACTLY ONE row, never two), and the boot must carry an fx.bootnonce=
 * (a row must be attributable to its boot, so a self-recorded row NEVER
 * carries "none" — and every offline caller, a CI host / a golden run /
 * a fixture with no PID1, records nothing).  The direct exec's row is
 * NARROWER than the handler's BY CONSTRUCTION and the header says so: the
 * handler records a request whether or not it took effect, while a direct
 * exec records only a PUBLISH THAT REACHED COMMIT.
 *
 * The journal's own header names what it does NOT cover, and the DERIVED
 * signature is RETAINED as the fallback for exactly that residue: a store
 * predating ca9cb06 (no .operator at all), and the paths that bypass
 * PID1's control handler AND the journal's own self-record (a host-side
 * `fxstore rollback`, `rollback --hard`, a hand-edited store CURRENT).  A
 * class never becomes more authoritative than its record: root in-guest
 * can forge or truncate the file exactly as it can .bootlog, and a row is
 * CHECKABLE against the store's version history, not authoritative over
 * it.
 *
 * THE CLAIM CLASS (the claim unit's S2) is MEASURED the same way.  The
 * judge seat fx-claim assembles the TRIPLE per generation — the claim
 * that rode in via the two extraEtc rows, the VERDICT the frozen policy's
 * evaluator reached, the OUTCOME cross-check — and persists it in
 * <store>.fx-claim-obs.  This seat reads that record: claim-record /
 * claim-verdict / claim-disagreement, with the §1a gap-3 discipline kept
 * in BOTH directions (a claimless row INSIDE the observation is a
 * MEASURED none-occurred; the observation's ABSENCE is
 * NOT-DURABLY-RECORDED, never a zero), plus the enrollment comparison: a
 * live generation the observation does not name is emitted NOT-RECORDED
 * with its disjunction stated — the judge has not run since the publish,
 * or its run disagreed (no-claim) and the observation kept its baseline.
 * The verdicts' vocabulary is the judge's; a word this report does not
 * know is surfaced verbatim with a note, never silently classified.
 *
 * ── THE BOUND, printed on every run (the audit seat's discipline) ──────
 * See the frozen BOUNDS[] table at the bottom of the tables below: the
 * runtime log's tmpfs death; the operator journal's own bounds (its two
 * named writers — PID1's control handler, and fx-activate's own publish
 * record where the boot carries a nonce — a store predating ca9cb06 has
 * none, root in-guest can forge or truncate it exactly as it can
 * .bootlog); the paths that BYPASS that handler and that self-record and
 * are therefore invisible to it (host-side `fxstore rollback`,
 * `rollback --hard`, a hand-edited CURRENT) with the DERIVED class's
 * retained disjunction for
 * them — an unattributed backward move is an operator rollback, OR a
 * same-input re-activation — MEASURED: two genuine activations one
 * second apart produced byte-equal facts — OR a removed .recovery row,
 * which the AUDIT seat's previous-observation comparison, not this seat,
 * is built to catch; nothing before the store's first snapshot; a
 * generation dir whose snapshot was pruned by `gc --retain` (MEASURED on
 * this tree: `fxstore gc` RETAINS every <genhash>-system-generation dir
 * a SURVIVING snapshot's generation fact names — the dir sweep's
 * carve-out — and reaps a dir whose snapshot was pruned, WITH its facts,
 * so a pruned generation's input is unreportable: absence-by-retention,
 * not a missing event); the renumber hazard after `rollback --hard`; and
 * the retention policy that is STATED and UNBOUNDED by the user's
 * decision (2026-10-12): .bootlog, .recovery and .operator are NEVER
 * pruned — dropping a row would break the roll-forward target
 * (bootlog_last/bootlog_newest_ok_below) and fx-audit's append
 * accounting, and a rotation reads as a REWRITE and fires on a HEALTHY
 * machine — at the NAMED cost of a full .bootlog rescan per boot, linear
 * in its length.  A
 * report that implies more than its records support is the failure mode
 * this whole project exists to argue against.
 *
 * Host tool (like the audit: native, no musl variant).  Links only the
 * vendored sha256.  Usage:
 *   fx-report [--store DIR] [--fxstore BIN] [--max-config-lines N]
 * Exit: 0 documented (no findings), 1 findings present, 2 tool error.
 */

#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include "dhall.h" /* sha256_hex (vendored dhall-c/sha256.c) */

/* ── knobs (every cap is LOUD on overflow: silently reporting a truncated
 *    view is exactly the silent pass this family refuses) ─────────────── */

#define MAX_VERSIONS 512
#define MAX_BOOTLOG_LINES 8192
#define MAX_RECOVERY_ROWS 2048
#define MAX_OPERATOR_ROWS 4096
#define MAX_CLAIM_ROWS 4096   /* the observation's claim rows (fx-claim caps
                               * its own at MAX_GENERATIONS=256; this cap is
                               * the report's own loud bound) */
/* fx-init REQ_MAX is 4096: the control channel's request token (the arg)
 * cannot exceed it, and operator_append's own line buffer is
 * REQ_MAX + 256.  OP_ARG_MAX is the sscanf field width for that field. */
#define OP_ARG_MAX 4095
#define MAX_FACT_ROWS 16384   /* total, across relations and versions */
#define LINE_MAX_ 8192
#define MAX_CONFIG_BYTES (8u * 1024 * 1024)

static unsigned opt_max_config_lines = 16384;

static const char *g_store = "/fx/store";
static const char *g_fxbin = NULL; /* --fxstore / $FXSTORE_BIN / "fxstore" */

/* ── loud failure / finding ────────────────────────────────────────────── */

static int g_findings = 0; /* exit 1 when non-zero */

static void die(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fputs("fx-report: FAIL: ", stderr);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
    exit(2);
}

static void *xmalloc(size_t n) {
    void *p = malloc(n ? n : 1);
    if (!p) die("out of memory");
    return p;
}

static void *xrealloc(void *p, size_t n) {
    p = realloc(p, n ? n : 1);
    if (!p) die("out of memory");
    return p;
}

static char *xstrdup(const char *s) {
    char *p = xmalloc(strlen(s) + 1);
    strcpy(p, s);
    return p;
}

/* ── output: machine records + `#` human summary ───────────────────────── */

/* human summary line — the `#` convention, same as .recovery's header */
static void h(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fputs("# ", stdout);
    vprintf(fmt, ap);
    putchar('\n');
    va_end(ap);
}

/* ── the record tables (parsed once, in chain order) ───────────────────── */

typedef struct {
    unsigned v;
    char cur;            /* 1 == the CURRENT version */
    char *genhash;       /* "-" when the version has no generation facts */
    char *epoch;         /* "-" likewise */
    char *buildfile;     /* generation fact col1, "-" when absent */
    char *dhake;         /* generation fact col2, "-" when absent */
    char *cfg_sha;       /* generation_config col1, "-" when absent */
    char *cfg_origin;    /* generation_config col2 (store-relative), "-" */
    /* populated lazily by read_config(): */
    char *cfg_bytes;     /* NULL until read; NULL + state=gone => missing */
    size_t cfg_len;
    char cfg_sha_actual[65];
    int cfg_read;        /* 0 not tried, 1 ok, -1 missing/unreadable */
} version_t;

static version_t g_vers[MAX_VERSIONS];
static unsigned g_nvers;

typedef struct {
    unsigned v;
    char status[64]; /* ok | failed | in-progress | shutdown (writer's set) */
    unsigned epoch;
    char nonce[96];  /* "-" when the line predates the nonce field */
    unsigned lineno;
} bootev_t;

static bootev_t g_bl[MAX_BOOTLOG_LINES];
static unsigned g_nbl;
static int g_bl_present, g_bl_empty; /* file existed / existed but had no line */

typedef struct {
    unsigned epoch;
    unsigned published;
    unsigned from_failed;
    char genhash[96]; /* "-" placeholder is legal (writer's) */
    char nonce[96];
    unsigned lineno;
} recrow_t;

static recrow_t g_rec[MAX_RECOVERY_ROWS];
static unsigned g_nrec;
static int g_rec_present;

/* One <store>/.operator row, in the writer's exact shape:
 *   <epoch-s> <action> <arg> <outcome> <from-version|-> <to-version|-> <nonce>
 * The arg is a control-channel request token (the ctrl arm tokenizes on
 * " \t", so it holds no whitespace) and is kept VERBATIM — it is the
 * operator's own operand, the thing the record exists to preserve. */
typedef struct {
    unsigned epoch;
    char action[32];   /* activate | rollback | shutdown (the writer's set) */
    char arg[OP_ARG_MAX + 1]; /* verbatim operand; "-" for shutdown */
    char outcome[64];  /* ok | failed:<rc> | refused | refused-config
                        * | dhake-failed | unverified */
    char from_s[16];   /* "-" = unknown / no generation move */
    char to_s[16];     /* "-" likewise */
    char nonce[96];    /* "none" = the host issued no nonce (hand-boot) */
    unsigned lineno;
} oprow_t;

static oprow_t g_op[MAX_OPERATOR_ROWS];
static unsigned g_nop;
static int g_op_present, g_op_empty; /* file existed / existed but had no row */

/* one facts row: relation, version, raw TSV tail (already tab-joined) */
typedef struct {
    const char *rel;
    unsigned v;
    char *tail;
} factrow_t;

static factrow_t g_facts[MAX_FACT_ROWS];
static unsigned g_nfacts;

/* One <store>.fx-claim-obs row (the judge seat's observation, format 1):
 *   claim <genhash> version <N> verdict <cls> claim-sha <sha|-> op-from <v|->
 * The sha is sha256(tsv bytes || le bytes) — the CLAIM's identity as the
 * seat recorded it; the reporter surfaces it, never recomputes it. */
typedef struct {
    char genhash[96];
    unsigned version;
    char verdict[80];
    char sha[80];       /* "-" when the generation was claimless */
    char opfrom[32];    /* the outcome cross-check's from-version, "-" */
    unsigned lineno;
} crow_t;

static crow_t g_crows[MAX_CLAIM_ROWS];
static unsigned g_ncrows;
static int g_clob_present; /* the observation file existed */

/* ── running fxstore (read-only subcommands only; the osier-share seat's
 *    pattern) ──────────────────────────────────────────────────────────── */

/* Paths interpolated into a popen'd command: refuse shell metacharacters
 * rather than quote (store paths are the caller's own flags). */
static void check_safe_path(const char *p, const char *what) {
    if (!p[0]) die("empty %s path", what);
    for (const char *q = p; *q; q++)
        if (*q == '\'' || *q == '"' || *q == '\\' || *q == ';' ||
            *q == '$' || *q == '`' || strchr(" \t\n", *q))
            die("unsafe character in %s path: %s", what, p);
}

/* Run `fxstore <args>`, die LOUDLY (exit 2) on non-zero.  Returns the
 * popen FILE — the caller reads and closes.  The reporter REFUSES to
 * guess past a failing reader. */
static FILE *fxstore_open(const char *args, const char *what) {
    check_safe_path(g_store, "--store");
    if (!g_fxbin) {
        const char *fb = getenv("FXSTORE_BIN");
        g_fxbin = xstrdup((fb && *fb) ? fb : "fxstore");
    }
    check_safe_path(g_fxbin, "--fxstore/FXSTORE_BIN");
    char *cmd;
    if (asprintf(&cmd, "'%s' %s --store '%s'", g_fxbin, args, g_store) < 0)
        die("out of memory");
    FILE *p = popen(cmd, "r");
    if (!p) die("cannot popen fxstore (%s)", strerror(errno));
    free(cmd);
    (void)what;
    return p;
}

/* Read one chomped line from a popen'd fxstore; dies on an over-long line
 * (a reader that would split it silently is worse than a loud refusal). */
static int fx_line(FILE *p, char *buf, size_t cap, const char *what) {
    if (!fgets(buf, (int)cap, p)) return 0;
    size_t l = strlen(buf);
    if (l && buf[l - 1] != '\n' && !feof(p))
        die("%s: fxstore produced a line longer than %zu bytes", what, cap - 1);
    while (l && (buf[l - 1] == '\n' || buf[l - 1] == '\r')) buf[--l] = 0;
    return 1;
}

static void fx_close(FILE *p, const char *what, const char *args) {
    int rc = pclose(p);
    if (rc != 0)
        die("%s: 'fxstore %s' failed (exit %d)", what, args,
            WIFEXITED(rc) ? WEXITSTATUS(rc) : -1);
}

/* ── split a TSV line in place into at most maxf fields; returns n ────── */
static size_t split_tabs(char *line, char **f, size_t maxf) {
    size_t n = 0;
    char *q = line;
    for (;;) {
        if (n < maxf) f[n] = q;
        n++;
        char *t = strchr(q, '\t');
        if (!t) break;
        *t = 0;
        q = t + 1;
    }
    return n; /* fields seen (may exceed maxf; extras stay glued to f[maxf-1]) */
}

/* ── the version chain ──────────────────────────────────────────────────── */

static void read_chain(void) {
    FILE *p = fxstore_open("timeline", "timeline");
    char line[LINE_MAX_];
    unsigned cur = 0, any = 0, vs[MAX_VERSIONS];
    unsigned nv = 0;
    while (fx_line(p, line, sizeof line, "timeline")) {
        unsigned v;
        if (sscanf(line, " %u", &v) != 1) continue;
        if (strstr(line, "[CURRENT]")) cur = v;
        if (nv >= MAX_VERSIONS)
            die("timeline lists more than %u versions — raise MAX_VERSIONS or gc --retain", (unsigned)MAX_VERSIONS);
        vs[nv++] = v;
        any = v;
    }
    fx_close(p, "timeline", "timeline");
    if (!any) die("store %s has no published snapshot", g_store);
    if (!cur) die("store %s marks no CURRENT snapshot — pass nothing and fix the store (dangling CURRENT)", g_store);
    /* timeline prints ascending; enforce it rather than trust it */
    for (unsigned i = 1; i < nv; i++)
        if (vs[i] <= vs[i - 1]) die("timeline versions not strictly ascending — reader bug or corrupt store");
    g_nvers = nv;
    for (unsigned i = 0; i < nv; i++) {
        version_t *V = &g_vers[i];
        memset(V, 0, sizeof *V);
        V->v = vs[i];
        V->cur = (vs[i] == cur);
        V->genhash = xstrdup("-");
        V->epoch = xstrdup("-");
        V->buildfile = xstrdup("-");
        V->dhake = xstrdup("-");
        V->cfg_sha = xstrdup("-");
        V->cfg_origin = xstrdup("-");
    }
}

/* per-version facts.  The five relations the report carries (§1a: "the
 * facts that describe it"); every row is emitted verbatim as a `fact`
 * record so the consumer sees exactly what the store says. */
static const char *const FACT_RELS[] = {
    "generation", "generation_config", "install", "provides", "src_of", "store"
};
#define N_FACT_RELS (sizeof FACT_RELS / sizeof FACT_RELS[0])

static void read_facts(void) {
    char args[128];
    for (unsigned i = 0; i < g_nvers; i++) {
        unsigned v = g_vers[i].v;
        for (size_t r = 0; r < N_FACT_RELS; r++) {
            snprintf(args, sizeof args, "facts %s --as-of %u", FACT_RELS[r], v);
            FILE *p = fxstore_open(args, "facts");
            char line[LINE_MAX_];
            while (fx_line(p, line, sizeof line, "facts")) {
                if (g_nfacts >= MAX_FACT_ROWS)
                    die("more than %u fact rows (version %u, relation %s) — raise MAX_FACT_ROWS or gc --retain",
                        (unsigned)MAX_FACT_ROWS, v, FACT_RELS[r]);
                /* keep the row for the `fact` records */
                g_facts[g_nfacts].rel = FACT_RELS[r];
                g_facts[g_nfacts].v = v;
                g_facts[g_nfacts].tail = xstrdup(line);
                g_nfacts++;
                /* and index the two the chain needs */
                char *f[8];
                size_t nf = split_tabs(line, f, 8);
                if (!strcmp(FACT_RELS[r], "generation") && nf >= 4) {
                    version_t *V = &g_vers[i];
                    free(V->genhash); free(V->epoch); free(V->buildfile); free(V->dhake);
                    V->genhash = xstrdup(f[0]);
                    V->buildfile = xstrdup(f[1]);
                    V->dhake = xstrdup(f[2]);
                    V->epoch = xstrdup(f[3]);
                } else if (!strcmp(FACT_RELS[r], "generation_config") && nf >= 3) {
                    version_t *V = &g_vers[i];
                    if (!strcmp(V->cfg_sha, "-")) { /* first row wins; extras still print as fact rows */
                        free(V->cfg_sha); free(V->cfg_origin);
                        V->cfg_sha = xstrdup(f[1]);
                        V->cfg_origin = xstrdup(f[2]);
                    }
                }
            }
            fx_close(p, "facts", args);
        }
    }
}

/* ── .bootlog / .recovery (fx-init's files; parsed in the writer's shape) ─ */

static void read_bootlog(void) {
    char path[4096];
    snprintf(path, sizeof path, "%s/.bootlog", g_store);
    FILE *f = fopen(path, "r");
    if (!f) {
        if (errno == ENOENT) { g_bl_present = 0; return; }
        die("cannot read %s: %s (a read error is not an absence)", path, strerror(errno));
    }
    g_bl_present = 1;
    char line[LINE_MAX_];
    unsigned ln = 0;
    while (fgets(line, sizeof line, f)) {
        ln++;
        size_t l = strlen(line);
        if (l && line[l - 1] != '\n' && !feof(f))
            die("%s:%u: line longer than %zu bytes — refusing to audit a truncated view",
                path, ln, sizeof line - 1);
        while (l && (line[l - 1] == '\n' || line[l - 1] == '\r')) line[--l] = 0;
        if (!l) continue;
        unsigned v, ep;
        char status[64], nonce[96];
        int n = sscanf(line, "%u %63s %u %95s", &v, status, &ep, nonce);
        if (n < 3)
            die("%s:%u: not the writer's shape \"<v> <status> <epoch> <nonce>\" (bootlog_append, init.zig): \"%s\"",
                path, ln, line);
        if (n == 3) snprintf(nonce, sizeof nonce, "-");
        if (g_nbl >= MAX_BOOTLOG_LINES)
            die("%s: more than %u lines — raise MAX_BOOTLOG_LINES (a report over a truncated view is a lie)",
                path, (unsigned)MAX_BOOTLOG_LINES);
        bootev_t *B = &g_bl[g_nbl++];
        B->v = v;
        snprintf(B->status, sizeof B->status, "%s", status);
        B->epoch = ep;
        snprintf(B->nonce, sizeof B->nonce, "%s", nonce);
        B->lineno = ln;
    }
    if (ferror(f)) die("read error on %s: %s", path, strerror(errno));
    fclose(f);
    g_bl_empty = (g_nbl == 0);
}

static void read_recovery(void) {
    char path[4096];
    snprintf(path, sizeof path, "%s/.recovery", g_store);
    FILE *f = fopen(path, "r");
    if (!f) {
        if (errno == ENOENT) { g_rec_present = 0; return; }
        die("cannot read %s: %s (a read error is not an absence)", path, strerror(errno));
    }
    g_rec_present = 1;
    char line[LINE_MAX_];
    unsigned ln = 0;
    while (fgets(line, sizeof line, f)) {
        ln++;
        size_t l = strlen(line);
        if (l && line[l - 1] != '\n' && !feof(f))
            die("%s:%u: line longer than %zu bytes — refusing a truncated view", path, ln, sizeof line - 1);
        while (l && (line[l - 1] == '\n' || line[l - 1] == '\r')) line[--l] = 0;
        if (!l) continue;
        if (line[0] == '#') continue; /* the writer's header */
        unsigned ep, pub, from;
        char gh[96], nonce[96];
        int n = sscanf(line, "%u %u %u %95s %95s", &ep, &pub, &from, gh, nonce);
        if (n < 4)
            die("%s:%u: not the writer's shape \"<epoch> <published> <from-failed> <genhash|-> <nonce>\" (recovery_append, init.zig): \"%s\"",
                path, ln, line);
        if (n == 4) snprintf(nonce, sizeof nonce, "-");
        if (g_nrec >= MAX_RECOVERY_ROWS)
            die("%s: more than %u data rows — raise MAX_RECOVERY_ROWS", path, (unsigned)MAX_RECOVERY_ROWS);
        recrow_t *R = &g_rec[g_nrec++];
        R->epoch = ep;
        R->published = pub;
        R->from_failed = from;
        snprintf(R->genhash, sizeof R->genhash, "%s", gh);
        snprintf(R->nonce, sizeof R->nonce, "%s", nonce);
        R->lineno = ln;
    }
    if (ferror(f)) die("read error on %s: %s", path, strerror(errno));
    fclose(f);
}

/* The writer's generation field: a decimal version, or "-" for unknown /
 * no move (operator_line's "{d}" / "-"). */
static int version_field_ok(const char *f) {
    if (!strcmp(f, "-")) return 1;
    if (!f[0]) return 0;
    for (const char *q = f; *q; q++)
        if (*q < '0' || *q > '9') return 0;
    return 1;
}

/* ── <store>/.operator (fx-init ca9cb06): the DURABLE operator journal ───
 *    The writer's shape is the contract, and this file's header is the
 *    DEFINITION (OPERATOR_HEADER, operator_journal.zig:122): one DATA line per
 *    control-channel intervention on the generation plane, INCLUDING the
 *    ones that failed or were refused — plus, since the runtime-record
 *    closure, the publishes fx-activate committed OUTSIDE that handler
 *    (same grammar, so the shape below covers both writers).  A line that
 *    does not match the shape is refused LOUDLY — never skipped, exactly as
 *    .bootlog/.recovery are — and the file's ABSENCE is its own state: a
 *    store predating ca9cb06 legitimately has none, and this seat must not
 *    turn that into "no interventions occurred". */
static void read_operator(void) {
    char path[4096];
    snprintf(path, sizeof path, "%s/.operator", g_store);
    FILE *f = fopen(path, "r");
    if (!f) {
        if (errno == ENOENT) { g_op_present = 0; return; }
        die("cannot read %s: %s (a read error is not an absence)", path, strerror(errno));
    }
    g_op_present = 1;
    char line[LINE_MAX_];
    unsigned ln = 0;
    while (fgets(line, sizeof line, f)) {
        ln++;
        size_t l = strlen(line);
        if (l && line[l - 1] != '\n' && !feof(f))
            die("%s:%u: line longer than %zu bytes — refusing to audit a truncated view",
                path, ln, sizeof line - 1);
        while (l && (line[l - 1] == '\n' || line[l - 1] == '\r')) line[--l] = 0;
        if (!l) continue;
        if (line[0] == '#') continue; /* the writer's header (the definition) */
        unsigned ep;
        char action[32], arg[OP_ARG_MAX + 1], outcome[64], froms[16], tos[16], nonce[96];
        /* 4095 == OP_ARG_MAX; the writer's arg is a request token (<= REQ_MAX). */
        int n = sscanf(line, "%u %31s %4095s %63s %15s %15s %95s",
                       &ep, action, arg, outcome, froms, tos, nonce);
        if (n != 7)
            die("%s:%u: not the writer's shape \"<epoch> <action> <arg> <outcome> <from-version|-> <to-version|-> <boot-nonce|none>\" (operator_append, init.zig): \"%s\"",
                path, ln, line);
        /* The generation pair is a decimal version or "-" in the writer's
         * vocabulary (operator_line's "{d}"/"-").  Checked explicitly: a
         * line of PROSE splits into seven fields just as happily, and a
         * silently accepted one would invent an operator action out of a
         * damaged file. */
        if (!version_field_ok(froms) || !version_field_ok(tos))
            die("%s:%u: the generation pair is not the writer's vocabulary (a decimal version or \"-\", operator_line, operator_journal.zig): \"%s\"",
                path, ln, line);
        if (g_nop >= MAX_OPERATOR_ROWS)
            die("%s: more than %u data rows — raise MAX_OPERATOR_ROWS (a report over a truncated view is a lie)",
                path, (unsigned)MAX_OPERATOR_ROWS);
        oprow_t *O = &g_op[g_nop++];
        O->epoch = ep;
        snprintf(O->action, sizeof O->action, "%s", action);
        snprintf(O->arg, sizeof O->arg, "%s", arg);
        snprintf(O->outcome, sizeof O->outcome, "%s", outcome);
        snprintf(O->from_s, sizeof O->from_s, "%s", froms);
        snprintf(O->to_s, sizeof O->to_s, "%s", tos);
        snprintf(O->nonce, sizeof O->nonce, "%s", nonce);
        O->lineno = ln;
    }
    if (ferror(f)) die("read error on %s: %s", path, strerror(errno));
    fclose(f);
    g_op_empty = (g_nop == 0);
}

static crow_t *crow_find(const char *genhash) {
    for (unsigned i = 0; i < g_ncrows; i++)
        if (!strcmp(g_crows[i].genhash, genhash)) return &g_crows[i];
    return NULL;
}

/* ── <store>.fx-claim-obs (fx-claim, the claim unit's S1): the judge ──────
 *    seat's DURABLE verdict record — the observation fx-claim writes under
 *    fx-audit's discipline (format-1 header, a store line, one claim row
 *    per generation, an end marker; tmp+rename).  The shape is the
 *    contract: a line that is not the judge's grammar is refused LOUDLY —
 *    never skipped, exactly as .operator is — and the file's ABSENCE is
 *    its own state: a store the judge never ran on legitimately has none,
 *    and this seat must not turn that into "no claims occurred" (the
 *    §1a gap-3 error).  The reporter does not re-verify the seat's
 *    store-binding (fx-claim refuses a carried observation itself); the
 *    rows are CHECKABLE against the timeline below, not authoritative
 *    over it. */
static void read_claimobs(void) {
    char path[4200];
    /* the judge binds the record to realpath(--store) (fx-claim.c:802,
     * :838): resolve the same way, so a symlinked or trailing-slash alias
     * of --store reads the record the judge wrote instead of missing it
     * and claiming a false absence.  An unresolvable store keeps the path
     * as given — the judge cannot have run on it, so the ENOENT below is
     * the true absence. */
    char rstore[4096];
    if (realpath(g_store, rstore))
        snprintf(path, sizeof path, "%s.fx-claim-obs", rstore);
    else
        snprintf(path, sizeof path, "%s.fx-claim-obs", g_store);
    FILE *f = fopen(path, "r");
    if (!f) {
        if (errno == ENOENT) { g_clob_present = 0; return; }
        die("cannot read %s: %s (a read error is not an absence)", path, strerror(errno));
    }
    g_clob_present = 1;
    char line[LINE_MAX_];
    unsigned ln = 0;
    int have_store = 0, ended = 0;
    while (fgets(line, sizeof line, f)) {
        ln++;
        size_t l = strlen(line);
        if (l && line[l - 1] != '\n' && !feof(f))
            die("%s:%u: line longer than %zu bytes — refusing to audit a truncated view",
                path, ln, sizeof line - 1);
        while (l && (line[l - 1] == '\n' || line[l - 1] == '\r')) line[--l] = 0;
        if (!l) continue;
        if (ln == 1) {
            if (strcmp(line, "fx-claim-observation 1") != 0)
                die("%s:1: not the judge seat's format-1 observation header — an "
                    "observation fx-claim did not write is not a record; "
                    "re-establish it with fx-claim --re-enroll", path);
            continue;
        }
        if (!strncmp(line, "store ", 6)) { have_store = 1; continue; }
        if (!strncmp(line, "claim ", 6)) {
            if (g_ncrows >= MAX_CLAIM_ROWS)
                die("%s: more than %u claim rows — raise MAX_CLAIM_ROWS (a report over a truncated view is a lie)",
                    path, (unsigned)MAX_CLAIM_ROWS);
            crow_t *C = &g_crows[g_ncrows];
            char sha[80], opf[32];
            int pos = -1;
            /* %n pins where the row grammar ENDS: an over-long LAST field
             * (op-from) or trailing content leaves bytes unconsumed and the
             * row dies LOUDLY instead of parsing truncated — width limits
             * alone only kill over-long NON-final fields (the following
             * literal fails to match); the last field has none after it. */
            if (sscanf(line + 6, "%95s version %u verdict %79s claim-sha %79s op-from %31s%n",
                       C->genhash, &C->version, C->verdict, sha, opf, &pos) != 5
                || pos < 0 || line[6 + (size_t)pos] != 0)
                die("%s:%u: not the judge seat's row shape \"claim <genhash> version <N> "
                    "verdict <cls> claim-sha <sha|-> op-from <v|->\" (fx-claim's "
                    "observation, format 1): \"%s\"", path, ln, line);
            /* a row repeating a genhash already parsed is not a judge record
             * (fx-claim writes ONE row per generation — it dedupes on first
             * appearance, fx-claim.c:930): half-read (crow_find takes the
             * first, the shadowed row is skipped) is the "never skipped"
             * discipline's own violation — refused, naming the genhash. */
            if (crow_find(C->genhash))
                die("%s:%u: duplicate observation row for generation %s — one row per "
                    "generation is the record's grammar", path, ln, C->genhash);
            snprintf(C->sha, sizeof C->sha, "%s", sha);
            snprintf(C->opfrom, sizeof C->opfrom, "%s", opf);
            C->lineno = ln;
            g_ncrows++;
            continue;
        }
        if (!strcmp(line, "end")) { ended = 1; break; }
        die("%s:%u: not the judge seat's observation grammar (\"fx-claim-observation 1\" "
            "| \"store <abs>\" | \"claim ...\" | \"end\"): \"%s\"", path, ln, line);
    }
    if (ferror(f)) die("read error on %s: %s", path, strerror(errno));
    fclose(f);
    if (!ended)
        die("%s: no end marker (a torn observation — fx-claim's tmp+rename makes one "
            "unreachable short of tampering)", path);
    if (!have_store)
        die("%s: records no store — an observation bound to no store is not a record", path);
}

/* The judge's verdict vocabulary, from fx-claim's own classes.  The
 * STATED set: ok; claimless (none-occurred, measured); skipped (the
 * outcome gate — no judgment).  The DISAGREEMENT set: refused-<name> (the
 * evaluator's refusals — hostile-compile, head-forgery, premise-false,
 * malformed-claim, justified-not-derived, ...), stale-world (the
 * outcome cross-check), not-a-claim.  Anything else is a vocabulary this
 * report does not know: surfaced verbatim with a note, never silently
 * classified — a NEWER judge's word must not read as coherent here. */
static int claim_verdict_disagrees(const char *v) {
    return !strncmp(v, "refused-", 8) || !strcmp(v, "stale-world") || !strcmp(v, "not-a-claim");
}
static int claim_cls_known(const char *v) {
    return !strcmp(v, "ok") || !strcmp(v, "claimless") || !strcmp(v, "skipped")
        || claim_verdict_disagrees(v);
}

/* The writer's refusal vocabulary, read from the record rather than
 * assumed: an intervention the journal shows did NOT take effect as
 * asked.  `failed:<rc>` and `refused-config` are the activate arm's
 * (init.zig:3665/:3730; refused-config is written by the rollback arm
 * too, :3856 — the writer calls it the same record from the other
 * direction), and refused-config means the generation DID land in the
 * store but PID1 REFUSED it: the declared service set is past its bound
 * OR the configuration could not be read at all (read_store_facts rc != 0,
 * the activate arm's two message forms at :3715/:3721 and the rollback
 * arm's at :3864/:3871).  `refused` is the rollback arm's when the STORE
 * rejected the target (:3858).  NOT refusals, and named as such in the
 * taxonomy:
 * `dhake-failed` (the generation DID land; the live-root reapply failed,
 * :3816) and `unverified` (the store could not be re-opened to confirm —
 * the record is AMBIGUOUS, which is not the same as refused), and `ok`. */
static int outcome_is_refusal(const char *o) {
    return !strncmp(o, "failed:", 7) || !strcmp(o, "refused") || !strcmp(o, "refused-config");
}

static int op_count_refusals(void) {
    unsigned n = 0;
    for (unsigned i = 0; i < g_nop; i++)
        if (outcome_is_refusal(g_op[i].outcome)) n++;
    return (int)n;
}

/* Does a journal row attribute a generation move TO version v?  Used only
 * to annotate a DERIVED signature the journal explains — it never
 * suppresses the derived row: the journal's own header says it cannot see
 * a host-side `fxstore rollback`, and reporting the journal as complete
 * would be the exact over-claim this seat refuses. */
static int op_attributes_to(unsigned v) {
    for (unsigned i = 0; i < g_nop; i++)
        if (strcmp(g_op[i].to_s, "-") && (unsigned)strtoul(g_op[i].to_s, NULL, 10) == v)
            return 1;
    return 0;
}

/* ── the retained config (the INPUT, readable — §1a gap 1's fix) ───────── */

static char *slurp_file(const char *path, size_t *len_out) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
    long sz = ftell(f);
    if (sz < 0 || (unsigned long)sz > MAX_CONFIG_BYTES) {
        fclose(f);
        if (sz > 0) die("%s: %ld bytes exceeds the %u-byte cap — raise MAX_CONFIG_BYTES", path, sz, MAX_CONFIG_BYTES);
        return NULL;
    }
    rewind(f);
    char *buf = xmalloc((size_t)sz + 1);
    if (sz && fread(buf, 1, (size_t)sz, f) != (size_t)sz) { free(buf); fclose(f); return NULL; }
    fclose(f);
    buf[sz] = 0;
    *len_out = (size_t)sz;
    return buf;
}

static void read_configs(void) {
    for (unsigned i = 0; i < g_nvers; i++) {
        version_t *V = &g_vers[i];
        if (!strcmp(V->cfg_origin, "-")) continue; /* absent-pre-link / bootstrap */
        char path[4096];
        snprintf(path, sizeof path, "%s/%s", g_store, V->cfg_origin);
        size_t len = 0;
        char *b = slurp_file(path, &len);
        if (!b) { V->cfg_read = -1; continue; }
        char sha[65];
        sha256_hex((const unsigned char *)b, (unsigned)len, sha);
        V->cfg_bytes = b;
        V->cfg_len = len;
        snprintf(V->cfg_sha_actual, sizeof V->cfg_sha_actual, "%s", sha);
        V->cfg_read = 1;
    }
}

/* ── line diff (Myers greedy, D-capped; the fallback — every line of A
 *    removed then every line of B added — is a CORRECT diff, merely not a
 *    minimal one; minimality is not a claim this report makes) ─────────── */

typedef struct {
    const char **a;
    unsigned na;
    const char **b;
    unsigned nb;
    /* backtrack path */
    int *vhist; /* (D+1) rows of (na+nb+1) ints */
    unsigned maxd;
} diff_t;

static const char **split_lines(const char *bytes, size_t len, unsigned *n_out) {
    /* count lines (a final unterminated fragment is a line) */
    unsigned n = 0;
    for (size_t i = 0; i < len; i++)
        if (bytes[i] == '\n') n++;
    if (len && bytes[len - 1] != '\n') n++;
    if (n > opt_max_config_lines)
        die("a retained config exceeds the %u-line cap — raise --max-config-lines (a report that silently truncates its INPUT is a lie)", opt_max_config_lines);
    const char **ls = xmalloc((n ? n : 1) * sizeof *ls);
    unsigned k = 0;
    const char *p = bytes;
    for (size_t i = 0; i < len; i++) {
        if (bytes[i] == '\n') {
            ls[k++] = p;
            p = bytes + i + 1;
        }
    }
    if (p < bytes + len) ls[k++] = p;
    *n_out = n;
    return ls;
}

static size_t line_len(const char *bytes, size_t len, const char *start) {
    const char *e = memchr(start, '\n', (size_t)(bytes + len - start));
    return e ? (size_t)(e - start) : (size_t)(bytes + len - start);
}

typedef struct {
    char op; /* '-', '+' */
    unsigned ln;
    const char *p;
    size_t len;
} diffl_t;

static diffl_t *g_diffout;
static unsigned g_ndiff, g_diffcap;

static void diff_emit(char op, unsigned ln, const char *p, size_t len) {
    if (g_ndiff == g_diffcap) {
        g_diffcap = g_diffcap ? g_diffcap * 2 : 256;
        g_diffout = xrealloc(g_diffout, g_diffcap * sizeof *g_diffout);
    }
    g_diffout[g_ndiff].op = op;
    g_diffout[g_ndiff].ln = ln;
    g_diffout[g_ndiff].p = p;
    g_diffout[g_ndiff].len = len;
    g_ndiff++;
}

/* classic Myers O((N+M)D) with the V-history backtrack; returns 0 ok,
 * -1 == D exceeded the cap (caller uses the fallback) */
static int myers(const char **a, unsigned na, const char **b, unsigned nb,
                 const char *abuf, size_t alen, const char *bbuf, size_t blen) {
    unsigned max = na + nb;
    if (max == 0) return 0;
    unsigned Dcap = max < 4096 ? max : 4096;
    /* V is indexed k+max+1 for k in [-Dcap..Dcap], so the array must span
     * 0..2*max+2 — a narrower buffer is an OOB write that silently
     * corrupts the edit script (caught by the gate's 2/2 count arm). */
    unsigned w = 2 * max + 3;
    int *vhist = xmalloc((Dcap + 1) * w * sizeof *vhist);
    int *V = xmalloc(w * sizeof *V);
    for (unsigned k = 0; k < w; k++) V[k] = 0;
    /* V[1] sentinel so k=1 at d=0 starts at x=0 */
    for (unsigned d = 0; d <= Dcap; d++) {
        for (int k = -(int)d; k <= (int)d; k += 2) {
            int x;
            if (k == -(int)d || (k != (int)d && V[(k - 1) + (int)max + 1] < V[(k + 1) + (int)max + 1]))
                x = V[(k + 1) + (int)max + 1]; /* down (insert from B) */
            else
                x = V[(k - 1) + (int)max + 1] + 1; /* right (delete from A) */
            int y = x - k;
            while ((unsigned)x < na && (unsigned)y < nb) {
                size_t la = line_len(abuf, alen, a[x]);
                size_t lb = line_len(bbuf, blen, b[y]);
                if (la != lb || memcmp(a[x], b[y], la)) break;
                x++; y++;
            }
            V[k + (int)max + 1] = x;
            if ((unsigned)x >= na && (unsigned)y >= nb) {
                /* backtrack */
                int cx = x, cy = y;
                for (int dd = (int)d; dd > 0; dd--) {
                    int *Vp = vhist + (size_t)(dd - 1) * w;
                    int kk = cx - cy;
                    int prevk;
                    if (kk == -dd || (kk != dd && Vp[(kk - 1) + (int)max + 1] < Vp[(kk + 1) + (int)max + 1]))
                        prevk = kk + 1; /* came via down */
                    else
                        prevk = kk - 1; /* came via right */
                    int px = Vp[prevk + (int)max + 1];
                    int py = px - prevk;
                    /* snakes from (px,py) to (cx,cy): diagonal moves are common */
                    while (cx > px && cy > py) { cx--; cy--; }
                    if (cx > px) { /* a deletion at line cx */
                        cx--;
                        diff_emit('-', (unsigned)(cx + 1), a[cx], line_len(abuf, alen, a[cx]));
                    } else if (cy > py) { /* an insertion of b line cy */
                        cy--;
                        diff_emit('+', (unsigned)(cy + 1), b[cy], line_len(bbuf, blen, b[cy]));
                    }
                }
                free(vhist); free(V);
                return 0;
            }
        }
        memcpy(vhist + (size_t)d * w, V, w * sizeof *V);
    }
    free(vhist); free(V);
    return -1;
}

/* Emit the collected ops in a FROZEN order a consumer can replay: all '-'
 * ascending by A-line, then all '+' ascending by B-line.  (The backtrack
 * emits newest-first; order by line number is the stable order.  Myers
 * touches each A-line at most once as a deletion and each B-line at most
 * once as an insertion, so both sub-orders are total.) */
static int diffl_cmp(const void *pa, const void *pb) {
    const diffl_t *a = pa, *b = pb;
    if (a->op != b->op) return a->op == '-' ? -1 : 1;
    return a->ln < b->ln ? -1 : (a->ln > b->ln ? 1 : 0);
}

static void diff_pair(const version_t *A, const version_t *B) {
    unsigned na = 0, nb = 0;
    const char **la = split_lines(A->cfg_bytes, A->cfg_len, &na);
    const char **lb = split_lines(B->cfg_bytes, B->cfg_len, &nb);
    g_ndiff = 0;
    if (myers(la, na, lb, nb, A->cfg_bytes, A->cfg_len, B->cfg_bytes, B->cfg_len) != 0) {
        /* fallback: full replacement — correct, not minimal */
        for (unsigned i = 0; i < na; i++)
            diff_emit('-', i + 1, la[i], line_len(A->cfg_bytes, A->cfg_len, la[i]));
        for (unsigned j = 0; j < nb; j++)
            diff_emit('+', j + 1, lb[j], line_len(B->cfg_bytes, B->cfg_len, lb[j]));
    }
    unsigned nminus = 0, nplus = 0;
    for (unsigned i = 0; i < g_ndiff; i++)
        if (g_diffout[i].op == '-') nminus++; else nplus++;
    qsort(g_diffout, g_ndiff, sizeof *g_diffout, diffl_cmp);
    for (unsigned i = 0; i < g_ndiff; i++) {
        printf("config-diff\t%u\t%u\t%c\t%u\t", A->v, B->v, g_diffout[i].op, g_diffout[i].ln);
        fwrite(g_diffout[i].p, 1, g_diffout[i].len, stdout);
        putchar('\n');
    }
    printf("config-diff-summary\t%u\t%u\t%u\t%u\n", A->v, B->v, nminus, nplus);
    free(la); free(lb);
}

/* ── the FROZEN tables, printed on every run (they ARE the grammar) ────── */

static const struct { const char *cls, *record, *absence; } TAXONOMY[] = {
    { "activation",
      "fxstore snapshots + facts:generation per version (every publish IS a snapshot)",
      "absence=none-occurred (within what survived gc --retain / renumber; a pruned activation is absence=not-recorded-ANYMORE)" },
    { "activation-input",
      "facts:generation_config(genhash,sha,origin) + the retained copy <store>/<origin> (fx-init 1399dbd)",
      "no-fact=absent-pre-link (a store-bootstrap snapshot or a pre-1399dbd activation: legitimate); fact+copy-gone=FINDING (the input is no longer readable)" },
    { "boot-verdict",
      "<store>/.bootlog line <v> ok|failed <epoch> <nonce> (fx-init bootlog_append)",
      "no-.bootlog=no-boot-ever-recorded; .bootlog-with-no-failed=none-failed-within-what-the-log-retains (the log is append-only and never pruned by the store)" },
    { "boot-start",
      "<store>/.bootlog line <v> in-progress <epoch> <nonce>",
      "a boot that started; a version with no line never started a recorded boot" },
    { "shutdown",
      "<store>/.bootlog line <v> shutdown <epoch> <nonce> (the SIGTERM path only)",
      "absence=no-RECORDED-clean-shutdown (a crash is indistinguishable from never shutting down — the log cannot say 'no shutdown happened')" },
    { "roll-forward-automatic",
      "<store>/.recovery data row <epoch> <published> <from-failed> <genhash> <nonce> (fx-init, once per successful roll-forward)",
      "no-file=no-automatic-roll-forward-ever-recorded; no-row-naming-v=v-was-not-published-by-the-automatic-path (within the file's retention)" },
    { "operator-intervention",
      "MEASURED — <store>/.operator rows: one line per intervention on the generation plane, written by PID1's control handler (fx-init ca9cb06) or, since the runtime-record closure, by fx-activate ITSELF for a publish it committed OUTSIDE that handler on a boot carrying an fx.bootnonce= (the file's own OPERATOR_HEADER, operator_journal.zig:122, IS the definition — ONE definition, imported by both writers): <epoch> <action> <arg> <outcome> <from-version|-> <to-version|-> <boot-nonce|none>, appended + fsync'd BEFORE the reply is flushed (operator_append: shutdown :3556, activate-failed :3665, unverified :3705, refused-config :3730, dhake-failed :3816, ok :3829, rollback unverified :3849, refused :3858, refused-config :3877, ok :3920).  SECOND WRITER (the runtime-record closure): fx-activate records the publish IT committed OUTSIDE that handler — one row, activate/ok or activate/unverified, on a boot carrying an fx.bootnonce= — through the SAME grammar and header (selfRecord, fx-init activate.zig:898/:1769/:1755; the writer itself, operator_journal.zig:235).  action = the ctrl arm that wrote it, arg = the operator's operand VERBATIM, outcome = ok | failed:<rc> | refused | refused-config | dhake-failed | unverified.  The journal records the GENERATION PLANE ONLY — its header names what it does NOT record (the reads, file transfers, the shell, per-service commands, probe) and what it cannot record AND cannot DETECT: the paths that bypass PID1's handler (host-side `fxstore rollback`, `rollback --hard`, a hand-edited CURRENT).  DERIVED — the RETAINED FALLBACK, for a store with NO .operator and for exactly those bypass paths: two signatures. (restore) version r whose genhash matches a version TWO-OR-MORE back (a duplicate of only the IMMEDIATELY-PRECEDING generation is fx-activate's own publish-of-live — MEASURED: every activation after the first leaves that benign pair — or gc's publish-first, and is NOT this class) and no .recovery row publishes r — the ctrl rollback arm (init.zig:3853) and host `fxstore rollback` drive the SAME soft rollback and append NOTHING to .recovery; (current-repoint) CURRENT != newest. Both are DERIVED, never a verdict.",
      "TWO DIFFERENT STATES, never conflated: (i) .operator PRESENT with zero rows = no generation-plane intervention in the retained journal — a MEASUREMENT, not a gap; (ii) .operator ABSENT = a store PREDATING ca9cb06 (or one never booted under it) — NOT 'none occurred' (see absence/.operator).  For (ii), and for the bypass paths the journal's own header lists as NOT-RECORDED-AND-NOT-DETECTABLE, the DERIVED signature is the fallback and it is a DISJUNCTION: an operator rollback OR a deliberate re-activation of an older config — either way content moved back without the automatic .recovery row — OR a removed .recovery row, which the AUDIT seat's previous-observation comparison, not this seat, is built to catch.  The derived signature is only a backward move or a stale CURRENT, and gc/renumber can destroy both.  A journal row does NOT suppress the derived row: it can EXPLAIN a backward move but cannot prove the journal saw every path that produced one." },
    { "activation-refusal",
      "MEASURED — <store>/.operator rows whose outcome is a refusal (fx-init ca9cb06): failed:<rc> (the activate executor exited rc; nothing landed — init.zig:3665), refused-config (the generation DID land in the store but PID1 REFUSED it — the declared service set past its bound, or a configuration read_store_facts could not read: :3730 from the activate arm, :3877 from the rollback arm, the writer's own 'same durable record from the other direction'), refused (the STORE rejected a rollback target — :3858).  Recorded in the SAME journal and NOT this class: dhake-failed (:3816 — the generation DID land, the live-root reapply failed) and unverified (:3705 — the store could not be re-opened to confirm, i.e. AMBIGUOUS, which is not the same as refused).  The tmpfs runtime log that held these (rt_effect activate failed|dhake-failed, init.zig:3667/:3818, DEFAULT_RUN :32) still dies at every reboot and is NOT read by this seat.",
      "no-row-with-a-refusal-outcome-in-the-retained-journal = no RECORDED refusal within the journal (a count of RECORDED refusals, never of attempts).  This absence-meaning WAS 'NOT-DURABLY-RECORDED' before ca9cb06 — a refused activation left NOTHING in the store (fx-activate refuses before touching it) and PID1's record of it lived in /run's tmpfs — and it is that again EXACTLY WHEN .operator IS ABSENT: a store predating the journal CANNOT answer this class, and the report says so via absence/.operator instead of printing a zero.  Bounds carried INTO the class: a REFUSAL row is written by PID1's control handler alone (a direct exec records only a publish that reached commit), so an fx-activate that refuses outside that handler is invisible; `unverified` rows are ambiguity, not refusals; and root in-guest can forge or truncate the file exactly as it can .bootlog — a row is CHECKABLE against the store's version/genhash history, not authoritative over it." },
    { "claim",
      "MEASURED — <store>.fx-claim-obs rows (the JUDGE SEAT's observation — fx-claim's format-1 record of the TRIPLE per generation: the claim that rode into the activation as the two extraEtc rows /etc/fx-claim.tsv + /etc/fx-claim.le, the VERDICT the frozen policy's evaluator reached, and the OUTCOME cross-check against the .operator row, content-joined): claim <genhash> version <N> verdict <cls> claim-sha <sha|-> op-from <v|-> (the observation's format header IS the definition — ONE writer).  The claim BYTES live in the retained generation dir (the claim-rows retention row); this seat reads the VERDICT record and recomputes nothing (bound/claim-check-is-a-lever)",
      "TWO DIRECTIONS, the §1a gap-3 discipline: (i) the observation PRESENT and a row's verdict claimless = NONE-OCCURRED for that generation — MEASURED by a judge that RAN, within the enrollment boundary the observation's existence sets; a LIVE generation the observation does NOT name is NOT 'none occurred' — the report emits claim-record ... NOT-RECORDED for it (the judge has not run since the publish, or its run disagreed — no-claim — and the observation kept its baseline); (ii) the observation ABSENT = NOT-DURABLY-RECORDED — no judge has ever run on this store (or the observation was removed): the report cannot say whether any claim rode in or any verdict was reached, and says so (absence/.fx-claim-obs) instead of printing a zero.  verdict-rewritten / claim-rewritten NEVER persist in the observation (the seat refuses to rewrite under them) — their audit is the judge's own next run, not this seat's" },
    { "content-recurrence",
      "DERIVED: .recovery data rows whose trailing genhash is IDENTICAL (the .recovery header's own semantics: the same content re-failing)",
      "no-repeated-genhash=no-recurrence-within-the-surviving-rows" },
};
#define NTAX (sizeof TAXONOMY / sizeof TAXONOMY[0])

static const struct {
    const char *rec, *where, *reboot, *rollfwd, *gc, *policy;
} RETENTION[] = {
    { "snapshots (versions+facts)", "<store>/.db/snapshots/<v>/ (the disk store)",
      "survives (disk)",
      "survives (a roll-forward PUBLISHES a new version)",
      "NOT-surviving: `fxstore gc --retain N` prunes at publish; after `rollback --hard` a later publish renumbers from CURRENT+1 (the gc --retain guard's own statement, store.zig) and can destroy the versions between",
      "DECIDED (user, 2026-10-12): UNBOUNDED by default — `gc --retain N` is the OPERATOR's deliberate knob and NOTHING SETS IT, the same decision as the journals below: every published version survives unless an operator asks otherwise (§1a gap 4 is now this DECISION, not a gap)" },
    { ".bootlog", "<store>/.bootlog (fx-init, append-only, fsync+syncfs per append)",
      "survives (disk)", "survives (append)",
      "survives (fxstore does not know the file; it outlives pruned versions)",
      "DECIDED (user, 2026-10-12): UNBOUNDED, and NOTHING MAY BE DROPPED — bootlog_last/bootlog_newest_ok_below need the newest `ok` below CURRENT (that IS the roll-forward TARGET), and fx-audit's append accounting + its previous-observation comparison need the record INTACT (a rotation reads as a REWRITE of a previously observed record and fires on a HEALTHY machine).  Growth is linear in events that really happened: the guardrail bounds it to real boots, one in-progress line per in-guest activation and one verdict per boot.  THE STATED COST, not hidden: the file is FULLY RESCANNED on every boot (bootlog_last/bootlog_newest_ok_below), so per-boot work is linear in its length (§1a gap 4 is now this DECISION, not a gap)" },
    { ".recovery", "<store>/.recovery (fx-init, '#'-header + one data row per automatic roll-forward)",
      "survives (disk)", "survives (append)",
      "survives (fxstore does not know the file)",
      "DECIDED (user, 2026-10-12): UNBOUNDED, and NOTHING MAY BE DROPPED — one row per AUTOMATIC roll-forward and the record stays INTACT (fx-audit's append accounting + its previous-observation comparison: a rotation reads as a REWRITE of a previously observed record and fires on a HEALTHY machine).  Growth is linear in roll-forwards that really happened (§1a gap 4 is now this DECISION, not a gap)" },
    { "retained config (the INPUT)", "<store>/<genhash>-system-generation/config.dhall (fx-activate, per activation)",
      "survives (disk)", "survives (each activation writes its own gen dir)",
      "RETAINED-WHILE-NAMED (MEASURED on this tree, store.zig pinned blob 30dce7cb: `fxstore gc <root>` keeps every <genhash>-system-generation dir named by a SURVIVING snapshot's generation fact — the dir sweep's carve-out, logged per dir on stderr; a dir whose snapshot was pruned by `gc --retain N` IS reaped, with its facts)",
      "DECIDED (user, 2026-10-12): UNBOUNDED by default — no pruning-by-age policy exists to state, because the copy is exactly as durable as the snapshot that names it (`gc --retain N` prunes version and dir together, and NOTHING sets that default): retention is bounded only by an operator's deliberate gc, never by time.  A GENUINELY missing copy (hand-deleted, or a dir a surviving fact names that is gone) still fires config-retained-copy-gone" },
    { "claim rows (the INPUT + the VERDICT record)", "<store>/<genhash>-system-generation/etc/fx-claim.tsv + fx-claim.le (fx-activate: the two extraEtc rows, installed 0o644 into the generation dir) + <store>.fx-claim-obs (fx-claim, the host-side verdict record, format-1 observation)",
      "survives (disk)", "survives (the rows ride in each activation's own gen dir; the observation is REWRITTEN per coherent run — tmp+rename, never appended)",
      "RETAINED-WHILE-NAMED (the rows live INSIDE the retained generation dir — exactly the retained-config carve-out above; the observation file fxstore does not know, and it outlives pruned versions — its rows for reaped generations are noted pruned-or-foreign, not dropped)",
      "DECIDED (user, 2026-10-12): UNBOUNDED by default — the claim bytes are exactly as durable as the snapshot that names them (gc prunes version and dir together); the observation's rewrite is the seat's own discipline, not a rotation: a rewritten verdict fires verdict-rewritten on the judge's next run, so the record cannot be silently rotated" },
    { ".operator", "<store>/.operator (fx-init ca9cb06, '#'-header + one data row per intervention on the generation plane — a control-channel REQUEST (appended+fsync'd by the handler BEFORE the reply is flushed, INCLUDING the ones that FAILED or were REFUSED) or, since the runtime-record closure, ONE row for a publish fx-activate committed OUTSIDE the handler on a boot carrying an fx.bootnonce= (a self-recorded row never carries \"none\"))",
      "survives (disk)", "survives (append — one row per ctrl request whatever its outcome, plus one per direct-exec publish where the boot carries a nonce)",
      "survives (fxstore does not know the file; it outlives pruned versions AND keeps rows naming versions gc has since pruned — a row records the move the operator asked for, it is not a promise the version is still there)",
      "DECIDED (user, 2026-10-12): UNBOUNDED, and NOTHING MAY BE DROPPED — one row per control-channel intervention and fx-audit's append accounting + its previous-observation comparison need the record INTACT (a rotation reads as a REWRITE of a previously observed record and fires on a HEALTHY machine).  Growth is linear in interventions that really happened, whose rate is the OPERATOR's own (§1a gap 4 is now this DECISION, not a gap).  NOT tamper-proof: PID1's control handler owns it and fx-activate adds one row for a publish committed outside that handler on a boot carrying a nonce (its TWO writers, in the file's own header), but root in-guest can forge or truncate it exactly as it can .bootlog" },
    { "runtime datalog rt_effect/rt_control", "/run/fx/log.db (fx-init init.zig:33 DEFAULT_RUN; path built :4856, opened :4857 by fx_log_open) — read by NOBODY here",
      "DOES NOT SURVIVE (post-pivot '/' is tmpfs, init.zig M4 pivot — the log dies at every reboot)",
      "n/a (dies with the boot that wrote it)",
      "n/a",
      "death-by-construction for the RUNTIME view only: the tmpfs log holds the live ctrl/effect stream, but every operator intervention it carried (activate, refused activate, dhake-failed, rollback, shutdown) is durably recorded SINCE fx-init ca9cb06 in <store>/.operator — and this seat reads THAT, never /run. What survives is what .bootlog/.recovery/.operator/snapshots hold/snapshots" },
    { "CURRENT", "<store>/.db/snapshots/CURRENT (atomic tmp+rename per publish/rollback)",
      "survives (disk)", "rewritten per publish (the roll-forward's own CURRENT)",
      "kept (gc --retain REFUSES a non-newest CURRENT rather than prune it)",
      "-" },
};
#define NRET (sizeof RETENTION / sizeof RETENTION[0])

static const struct { const char *id, *text; } BOUNDS[] = {
    { "rt-log-tmpfs",
      "the runtime datalog's live ctrl/effect stream (activations, refused activations, rollbacks, shutdowns) lived at /run/fx/log.db and is GONE at every reboot (tmpfs post-pivot) — this report never reads it.  Since fx-init ca9cb06 those same interventions are ALSO written durably to <store>/.operator, and THIS seat reads that file instead (operator_append is called BEFORE the reply is flushed, so the row outlives a machine killed right after the answer).  The bound is therefore now a property of the STORE, not of the report: without .operator (a store predating the journal) nothing durable can say whether an activation was refused." },
    { "pre-first-snapshot",
      "nothing before the store's first snapshot is representable; a .bootlog line naming a version not in the timeline is reported as such (pruned by gc, or written by a store history this disk no longer holds)" },
    { "operator-journal-bounds",
      "<store>/.operator is the durable operator record SINCE fx-init ca9cb06, and it is bounded on every side: it holds the GENERATION PLANE only, and only what PID1's control handler saw — plus, since the RUNTIME-RECORD CLOSURE, the publishes fx-activate committed OUTSIDE that handler (a direct exec: the harness's channel-less fallback, or a command in the interactive shell) on a boot carrying an fx.bootnonce=, ONE row each and only when the publish REACHED COMMIT (a pre-publish failure records nothing: there is no request to attribute it to).  The file's own header (OPERATOR_HEADER, operator_journal.zig:122) names what it does NOT record — the reads (status/q/grep/search), file transfers (put/rm), per-service commands (start/stop/restart), probe, and a malformed request no arm executed; the `shell` REQUEST is still not recorded, although a DIRECT exec FROM that shell now records its own publish — and what is NOT recorded AND NOT DETECTABLE: a host-side `fxstore rollback`, `rollback --hard`, a hand-edited store CURRENT.  Root in-guest can forge or truncate the file exactly as it can .bootlog: a row is CHECKABLE against the store's version/genhash history, not authoritative over it.  A store predating the journal has NO file at all — absence of the FILE is a state of the store, never 'no interventions occurred'." },
    { "operator-bypass-paths",
      "the paths that bypass PID1's control handler have NO record: host-side `fxstore rollback`, `rollback --hard`, and a hand-edited store CURRENT.  A DIRECT EXEC of fx-activate is no longer one of them — it records its own publish on a boot carrying an fx.bootnonce= (the runtime-record closure) — but that row covers exactly its OWN publish, so these three remain the unrecorded set.  Their only durable trace is a generation move the automatic .recovery row does not attribute, so the DERIVED operator-intervention signature is RETAINED as the fallback for them — and it is a DISJUNCTION: an operator rollback, a deliberate re-activation of an older config, or a REMOVED .recovery row (which the AUDIT seat's previous-observation comparison, not this seat, is built to catch).  A rollback to the content that is ALREADY current moves nothing and is invisible in this class by construction.  A journal row can EXPLAIN a derived backward move; it never suppresses the derived row, because the journal cannot prove it saw every path that produced one." },
    { "gc-config-loss",
      "MEASURED on this tree: `fxstore gc <root>` RETAINS every <genhash>-system-generation dir a SURVIVING snapshot's generation fact names (the dir sweep's carve-out) and REAPS a dir whose snapshot was pruned by `gc --retain N` — with its facts, so the pruned generation's input is not reportable at all (the version is gone from the timeline: absence-by-retention, not a finding). config-retained-copy-gone therefore requires a GENUINELY missing copy (a hand-deleted file, or a dir a surviving fact names that is gone) — the post-gc store itself is COHERENT" },
    { "renumber-after-hard",
      "after `rollback --hard` (CURRENT < newest), a later publish renumbers from CURRENT+1 and can destroy the versions between (stated by the gc --retain guard, store.zig; not reproduced here) — the CURRENT!=newest signature is therefore TRANSIENT, visible only until that next publish" },
    { "retention-unbounded-by-decision",
      "BY DECISION, NOT BY OMISSION (user, 2026-10-12; §1a gap 4 is now a policy): `.bootlog`, `.recovery` and `.operator` grow WITHOUT BOUND and NOTHING MAY BE DROPPED — `bootlog_last`/`bootlog_newest_ok_below` need the newest `ok` below CURRENT (that IS the roll-forward TARGET), and fx-audit's append accounting + its previous-observation comparison need the record INTACT (a rotation reads as a REWRITE of a previously observed record and would fire on a HEALTHY machine).  Growth is linear in events that really happened: real boots, one in-progress line per in-guest activation, one `.recovery` row per automatic roll-forward, one `.operator` row per intervention.  THE STATED COST, not hidden: `.bootlog` is FULLY RESCANNED on every boot, so per-boot work is linear in its length.  The snapshots keep their knob (`gc --retain N`) and NOTHING sets a default — the same decision" },
    { "claim-rides-in-extraEtc",
      "the claim rides INTO the activation as two PLAIN extraEtc rows (/etc/fx-claim.tsv — the row claim<TAB>contention<TAB>from_version<TAB>S_from — and /etc/fx-claim.le — the agent's own LE argument over the host's closed lexicon): a CONVENTION, not a schema — any extraEtc file at those paths reads as a claim, and one that does not parse is refused LOUD by the judge (malformed-claim / not-a-claim), never silently read as claimless.  The rows are CONTENT: they cannot change under a live genhash (different bytes are a different generation), and a claimless generation's dir that GAINS claim bytes is claim-rewritten.  The promotion to a real config field (the claim(...) relation at fx-activate's validation, S3) is named, not built" },
    { "claim-obs-is-host-side",
      "the verdict record <store>.fx-claim-obs is HOST-side by construction: fx-claim REFUSES an observation location inside the store, keys it to the store's ABSOLUTE path (a carried copy is refused — an observation between stores proves nothing) and rewrites it tmp+rename.  THIS report reads the default sibling path of the store's RESOLVED path (realpath — the same binding fx-claim writes the record under, fx-claim.c:802/:838), so a symlinked or trailing-slash alias of --store still reads the record that exists; an observation written via --obs-dir DIR is INVISIBLE here — stated, not guessed.  Its rows are CHECKABLE against the store's generation history, not authoritative over it: a row whose genhash no live generation carries is noted pruned-or-foreign" },
    { "claim-check-is-a-lever",
      "the claim check is AUDITING, not PROOFING (design record §6b's stance): the RECORD is what you rely on — the observation's verdicts and the named disagreement classes are the durable account — and the DENIAL (the frozen policy's does-not-derive, refused by name at a commit point) is the LEVER that makes the agent repair its world model.  This seat therefore derives NOTHING about justification: it surfaces the judge's verdicts verbatim, names the disagreement classes among them, and states the record's COVERAGE — it never re-runs the evaluation" },
    { "claim-evaluator-location",
      "the evaluator's LOCATION — host-side Python (policy/eval_claim.py over the le checkout) TODAY, a DEPLOYMENT STOPGAP; in-guest in the qemu lane (the le->Osier port emitting x64 via QBE) once the port lands — is a DEPLOYMENT DIFFERENCE WITH IDENTICAL SEMANTICS: the same closed agent lexicon (policy/claims-lexicon.ini), the same frozen policy (policy/claims-policy.dl, sha-pinned in policy/PINS), the same claim bytes, the same record format.  The verdict does not encode where the evaluator ran and the record does not say — because it does not matter: this row exists so the location can never silently become a reason to shrink the language again (round 1 chose a crippled template checker to avoid executing LE, and was overturned for exactly that)" },
    { "same-store-only",
      "this report is a function of ONE store directory; anything recorded elsewhere (the runtime log, the harness's own transcript, the audit's observation file) is out of domain, and the report never guesses at it — the ONE in-domain exception is the judge seat's claim observation <store>.fx-claim-obs (bound/claim-obs-is-host-side), which is the claim class's record, not a harness self-report" },
};
#define NBOUND (sizeof BOUNDS / sizeof BOUNDS[0])

/* ── main ───────────────────────────────────────────────────────────────── */

/* For version index i (which must carry a genhash): the index of the
 * NEAREST earlier genhash-bearing version, and the index of the NEWEST
 * earlier version carrying the SAME genhash (-1s when none).  Scanning
 * DOWNWARD is the point: "nearest" is the immediately-preceding
 * generation, and a duplicate of exactly it is the benign publish-of-live
 * pair, not a restore. */
static void dup_targets(unsigned i, int *nearest, int *match) {
    *nearest = -1;
    *match = -1;
    for (int j = (int)i - 1; j >= 0; j--) {
        if (!strcmp(g_vers[j].genhash, "-")) continue;
        if (*nearest < 0) *nearest = j;
        if (*match < 0 && !strcmp(g_vers[j].genhash, g_vers[i].genhash)) *match = j;
    }
}

static int recrow_names(unsigned v) {
    for (unsigned i = 0; i < g_nrec; i++)
        if (g_rec[i].published == v) return 1;
    return 0;
}

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--store") && i + 1 < argc) g_store = argv[++i];
        else if (!strncmp(argv[i], "--store=", 8)) g_store = argv[i] + 8;
        else if (!strcmp(argv[i], "--fxstore") && i + 1 < argc) g_fxbin = xstrdup(argv[++i]);
        else if (!strncmp(argv[i], "--fxstore=", 10)) g_fxbin = xstrdup(argv[i] + 10);
        else if (!strcmp(argv[i], "--max-config-lines") && i + 1 < argc)
            opt_max_config_lines = (unsigned)strtoul(argv[++i], NULL, 10);
        else if (!strncmp(argv[i], "--max-config-lines=", 19))
            opt_max_config_lines = (unsigned)strtoul(argv[i] + 19, NULL, 10);
        else if (!strcmp(argv[i], "--help")) {
            printf("usage: fx-report [--store DIR] [--fxstore BIN] [--max-config-lines N]\n");
            return 0;
        } else {
            fprintf(stderr, "fx-report: unknown argument '%s'\n", argv[i]);
            return 2;
        }
    }
    if (opt_max_config_lines == 0) die("--max-config-lines must be >= 1");

    read_chain();
    read_facts();
    read_bootlog();
    read_recovery();
    read_operator();
    read_claimobs();
    read_configs();

    /* ── the human header ─────────────────────────────────────────────── */
    h("fx-report — the REPORTER seat (host-side, agent-unwritable, a function");
    h("of observable system state; design record §1a/§7.1).  Machine records");
    h("are the non-'#' lines: tab-separated, frozen column order per tag.");
    h("Every record is marked MEASURED / DERIVED / ABSENT, and every ABSENT");
    h("says WHICH kind of absence it is.  The taxonomy and retention tables");
    h("below are printed on every run — they are the grammar, not commentary.");

    /* ── the frozen tables (machine lines first, so a consumer that stops");
       reading at the first non-table line still has them) ─────────────── */
    for (size_t t = 0; t < NTAX; t++)
        printf("taxonomy\t%s\t%s\t%s\n", TAXONOMY[t].cls, TAXONOMY[t].record, TAXONOMY[t].absence);
    for (size_t t = 0; t < NRET; t++)
        printf("retention\t%s\t%s\t%s\t%s\t%s\t%s\n", RETENTION[t].rec, RETENTION[t].where,
               RETENTION[t].reboot, RETENTION[t].rollfwd, RETENTION[t].gc, RETENTION[t].policy);
    for (size_t t = 0; t < NBOUND; t++)
        printf("bound\t%s\t%s\n", BOUNDS[t].id, BOUNDS[t].text);

    /* ── the store and the chain ──────────────────────────────────────── */
    unsigned cur_v = 0, newest = g_vers[g_nvers - 1].v;
    for (unsigned i = 0; i < g_nvers; i++)
        if (g_vers[i].cur) cur_v = g_vers[i].v;
    printf("report\tfx-report/1\tstore\t%s\tversions\t%u\n", g_store, g_nvers);
    printf("current\t%u\tMEASURED\tnewest\t%u\n", cur_v, newest);

    /* absence records: the files the events come from */
    if (!g_bl_present)
        printf("absence\t.bootlog\tno-boot-ever-recorded\tABSENT\n");
    else if (g_bl_empty)
        printf("absence\t.bootlog\tpresent-but-empty\tABSENT\n");
    if (!g_rec_present)
        printf("absence\t.recovery\tno-automatic-roll-forward-recorded\tABSENT\n");
    /* .operator's absence is its OWN state, not "no interventions": the
     * writer's header is ensured on every store at boot (operator_ensure,
     * init.zig:964), so a file that is not there is a store that never
     * booted under ca9cb06 — the derived fallback's domain. */
    if (!g_op_present)
        printf("absence\t.operator\tno-operator-journal-this-store-predates-fx-init-ca9cb06-or-never-booted-under-it\tABSENT\n");
    else if (g_op_empty)
        printf("absence\t.operator\tpresent-but-empty-no-intervention-recorded\tABSENT\n");
    printf("absence\trt-log\t/run/fx/log.db-not-durably-recorded-tmpfs\tABSENT\n");
    /* the claim observation's absence is its OWN state, exactly as
     * .operator's: no judge has ever enrolled this store (or the
     * observation was removed) — 'none occurred' is NOT derivable from
     * nothing, and the coverage pass below names what the record misses. */
    if (!g_clob_present)
        printf("absence\t.fx-claim-obs\tnot-durably-recorded-no-judge-observation-no-fx-claim-run-has-ever-enrolled-this-store-or-the-observation-was-removed\tABSENT\n");
    else if (g_ncrows == 0)
        printf("absence\t.fx-claim-obs\tpresent-but-empty-the-judge-enrolled-on-a-store-with-no-published-generation\tABSENT\n");

    /* versions, in chain order */
    for (unsigned i = 0; i < g_nvers; i++) {
        version_t *V = &g_vers[i];
        const char *state;
        if (!strcmp(V->cfg_origin, "-"))
            state = !strcmp(V->genhash, "-") ? "absent-no-generation-facts" : "absent-pre-link";
        else if (V->cfg_read < 0) {
            state = "finding-copy-missing";
            printf("finding\tconfig-retained-copy-gone\tversion\t%u\torigin\t%s\tMEASURED (generation_config names it; the file is not there)\n",
                   V->v, V->cfg_origin);
            g_findings++;
        } else if (strcmp(V->cfg_sha, V->cfg_sha_actual)) {
            state = "finding-sha-mismatch";
            printf("finding\tconfig-sha-mismatch\tversion\t%u\tfact\t%s\tbytes\t%s\tMEASURED (the retained copy is not the bytes the fact hashed)\n",
                   V->v, V->cfg_sha, V->cfg_sha_actual);
            g_findings++;
        } else state = "retained";
        unsigned n_boot = 0;
        for (unsigned k = 0; k < g_nbl; k++)
            if (g_bl[k].v == V->v) n_boot++;
        unsigned n_rec = 0;
        for (unsigned k = 0; k < g_nrec; k++)
            if (g_rec[k].published == V->v) n_rec++;
        unsigned n_f = 0;
        for (unsigned k = 0; k < g_nfacts; k++)
            if (g_facts[k].v == V->v) n_f++;
        printf("version\t%u\t%s\t%s\t%s\t%s\t%s\t%s\tfacts\t%u\tboots\t%u\trollforwards\t%u\tMEASURED\n",
               V->v, V->cur ? "current" : "-", V->genhash, V->epoch, V->buildfile, V->dhake,
               state, n_f, n_boot, n_rec);
        if (V->cfg_read == 1) {
            printf("config\t%u\t%s\t%s\t%s\tMEASURED\n", V->v, V->cfg_sha, V->cfg_origin, state);
            /* the INPUT, readable: one record per line */
            unsigned n = 0;
            const char **ls = split_lines(V->cfg_bytes, V->cfg_len, &n);
            for (unsigned k = 0; k < n; k++) {
                printf("config-line\t%u\t%u\t", V->v, k + 1);
                size_t L = line_len(V->cfg_bytes, V->cfg_len, ls[k]);
                /* escape without a NUL-terminated copy: emit in place */
                for (size_t c = 0; c < L; c++) {
                    unsigned char ch = (unsigned char)ls[k][c];
                    switch (ch) {
                    case '\\': fputs("\\\\", stdout); break;
                    case '\t': fputs("\\t", stdout); break;
                    case '\r': fputs("\\r", stdout); break;
                    default:
                        if (ch < 0x20 || ch == 0x7f) printf("\\x%02x", ch);
                        else putchar(ch);
                    }
                }
                putchar('\n');
            }
            free(ls);
        }
        /* the facts rows of this version, verbatim */
        for (unsigned k = 0; k < g_nfacts; k++)
            if (g_facts[k].v == V->v)
                printf("fact\t%s\t%u\t%s\n", g_facts[k].rel, g_facts[k].v, g_facts[k].tail);
    }

    /* ── events, one class per record source, in the taxonomy's terms ─── */

    /* activation: every published version (the snapshot IS the record).
     * MEASURED: every fx-activate run after the first leaves a BENIGN PAIR —
     * a duplicate of the previous generation (its own publish of the live
     * WAL before clearing the facts), then the new generation — so a
     * duplicate of only the IMMEDIATELY-PRECEDING generation is kind
     * republish-live and NOT an intervention; content moving two-or-more
     * versions back is a RESTORE (kind restore), the shape both the
     * automatic roll-forward and the operator rollback produce. */
    for (unsigned i = 0; i < g_nvers; i++) {
        version_t *V = &g_vers[i];
        const char *kind = "activation";
        char republish[32] = "-";
        if (strcmp(V->genhash, "-")) {
            int nearest = -1, match = -1;
            dup_targets(i, &nearest, &match);
            if (match >= 0) {
                if (match == nearest)
                    kind = "republish-live"; /* dup of the live generation */
                else
                    kind = "restore"; /* content moved 2+ versions back */
                snprintf(republish, sizeof republish, "%u", g_vers[match].v);
            }
        } else kind = "no-generation-facts";
        printf("event\tactivation\tMEASURED\tversion\t%u\tgenhash\t%s\tepoch\t%s\tkind\t%s\trepublish-of\t%s\n",
               V->v, V->genhash, V->epoch, kind, republish);
    }

    /* boot verdicts, in the log's own order */
    for (unsigned i = 0; i < g_nbl; i++) {
        bootev_t *B = &g_bl[i];
        int in_chain = 0;
        for (unsigned j = 0; j < g_nvers; j++)
            if (g_vers[j].v == B->v) in_chain = 1;
        printf("event\tboot-verdict\tMEASURED\tversion\t%u\tstatus\t%s\tepoch\t%u\tnonce\t%s\tline\t%u%s\n",
               B->v, B->status, B->epoch, B->nonce, B->lineno,
               in_chain ? "" : "\tnote\tversion-not-in-timeline-pruned-or-foreign");
    }

    /* automatic roll-forwards, from .recovery's own rows */
    for (unsigned i = 0; i < g_nrec; i++) {
        recrow_t *R = &g_rec[i];
        int in_chain = 0;
        for (unsigned j = 0; j < g_nvers; j++)
            if (g_vers[j].v == R->published) in_chain = 1;
        printf("event\troll-forward-automatic\tMEASURED\tepoch\t%u\tpublished\t%u\tfrom-failed\t%u\tgenhash\t%s\tnonce\t%s\tline\t%u%s\n",
               R->epoch, R->published, R->from_failed, R->genhash, R->nonce, R->lineno,
               in_chain ? "" : "\tnote\tpublished-version-not-in-timeline");
    }

    /* content recurrence: identical trailing genhashes across rows */
    for (unsigned i = 0; i < g_nrec; i++)
        for (unsigned j = i + 1; j < g_nrec; j++)
            if (!strcmp(g_rec[i].genhash, g_rec[j].genhash) && strcmp(g_rec[i].genhash, "-"))
                printf("event\tcontent-recurrence\tDERIVED\tgenhash\t%s\trows\t%u,%u\tsame-content-refailing (the .recovery header's own semantics)\n",
                       g_rec[i].genhash, i + 1, j + 1);

    /* operator intervention — MEASURED from <store>/.operator, the DURABLE
     * journal fx-init ca9cb06 writes from PID1's control handler: one row
     * per generation-plane intervention, INCLUDING the ones that failed or
     * were refused, fsync'd BEFORE the reply is flushed.  Each row carries
     * its own vault: action, the operator's VERBATIM operand, the outcome,
     * the generation pair and the boot nonce.  This is the record the
     * class was missing; the DERIVED fallback below is RETAINED for what
     * the journal CANNOT see — a store predating it, and the bypass paths
     * its own header names. */
    for (unsigned i = 0; i < g_nop; i++) {
        oprow_t *O = &g_op[i];
        int from_in = 1, to_in = 1;
        if (strcmp(O->from_s, "-")) {
            from_in = 0;
            for (unsigned j = 0; j < g_nvers; j++)
                if (g_vers[j].v == (unsigned)strtoul(O->from_s, NULL, 10)) from_in = 1;
        }
        if (strcmp(O->to_s, "-")) {
            to_in = 0;
            for (unsigned j = 0; j < g_nvers; j++)
                if (g_vers[j].v == (unsigned)strtoul(O->to_s, NULL, 10)) to_in = 1;
        }
        printf("event\toperator-intervention\tMEASURED\tfile\t.operator\tline\t%u\tepoch\t%u\taction\t%s\targ\t%s\toutcome\t%s\tfrom-version\t%s\tto-version\t%s\tnonce\t%s%s%s\n",
               O->lineno, O->epoch, O->action, O->arg, O->outcome, O->from_s, O->to_s, O->nonce,
               from_in ? "" : "\tnote\tfrom-version-not-in-timeline-pruned-or-foreign",
               to_in ? "" : "\tnote\tto-version-not-in-timeline-pruned-or-foreign");
    }

    /* activation refusal — MEASURED from the SAME rows.  The class whose
     * absence-meaning was NOT-DURABLY-RECORDED: fx-activate refuses before
     * touching the store, so the only durable trace is PID1's own row for
     * the request it could not carry out.  `failed:<rc>`, `refused` and
     * `refused-config` are refusals; `dhake-failed` (the generation DID
     * land) and `unverified` (ambiguous — the store could not be
     * re-opened) are recorded in the same file and are NOT this class. */
    for (unsigned i = 0; i < g_nop; i++) {
        oprow_t *O = &g_op[i];
        if (!outcome_is_refusal(O->outcome)) continue;
        printf("event\tactivation-refusal\tMEASURED\tfile\t.operator\tline\t%u\tepoch\t%u\taction\t%s\targ\t%s\toutcome\t%s\tfrom-version\t%s\tto-version\t%s\tnonce\t%s\n",
               O->lineno, O->epoch, O->action, O->arg, O->outcome, O->from_s, O->to_s, O->nonce);
    }

    /* operator intervention — the DERIVED class, with its bound inline.
     * RESTORE-kind versions only: the nearest earlier generation with a
     * genhash must DIFFER (a dup of the immediately-preceding generation
     * is the benign publish-of-live pair, kind republish-live).  A journal
     * row that names this version ANNOTATES the derivation; it never
     * suppresses it — the journal cannot prove it saw the path that moved
     * the content. */
    for (unsigned i = 0; i < g_nvers; i++) {
        version_t *V = &g_vers[i];
        if (!strcmp(V->genhash, "-")) continue;
        int nearest = -1, match = -1;
        dup_targets(i, &nearest, &match);
        if (match < 0 || match == nearest) continue; /* new content / benign pair */
        if (recrow_names(V->v)) continue; /* the automatic path recorded it */
        printf("event\toperator-intervention\tDERIVED\tshape\trestore\tversion\t%u\tgenhash\t%s\trepresents\t%u\tbound\tdisjunction: operator-rollback-OR-re-activation-of-older-config-OR-removed-recovery-row (bound/operator-bypass-paths)%s\n",
               V->v, V->genhash, g_vers[match].v,
               op_attributes_to(V->v) ? "\tnote\tjournal-attributes-a-move-to-this-version" : "");
    }
    if (cur_v != newest)
        printf("event\toperator-intervention\tDERIVED\tshape\tcurrent-repoint\tcurrent\t%u\tnewest\t%u\tbound\tdisjunction: rollback-hard-OR-torn-publish (bound/renumber-after-hard; the signature is transient)\n",
               cur_v, newest);

    /* ── the claim records — MEASURED from <store>.fx-claim-obs, the judge
     * seat's observation (fx-claim's durable record of the TRIPLE: the
     * claim that rode in via the extraEtc rows, the verdict the frozen
     * policy's evaluator reached, the outcome cross-check).  The reporter
     * RELIES ON the record and derives nothing about justification
     * (bound/claim-check-is-a-lever): it surfaces the verdicts, names the
     * DISAGREEMENT classes among them, and — the enrollment comparison —
     * names every LIVE generation the observation does NOT cover, for
     * which 'none occurred' is NOT derivable (the judge has not run since
     * the publish, or its run disagreed and the observation kept its
     * baseline).  First appearance is a generation's canonical version —
     * the same canonicalization the judge seat states: a re-landing shares
     * the genhash and the one record. */
    for (unsigned i = 0; i < g_nvers; i++) {
        version_t *V = &g_vers[i];
        if (!strcmp(V->genhash, "-")) continue;
        int seen = 0;
        for (unsigned j = 0; j < i; j++)
            if (!strcmp(g_vers[j].genhash, V->genhash)) { seen = 1; break; }
        if (seen) continue;
        crow_t *C = crow_find(V->genhash);
        if (C) {
            printf("claim-record\t%s\tversion\t%u\tclaim-sha\t%s\top-from\t%s\tMEASURED\n",
                   C->genhash, C->version, C->sha, C->opfrom);
            if (claim_cls_known(C->verdict))
                printf("claim-verdict\t%s\tverdict\t%s\tMEASURED\n", C->genhash, C->verdict);
            else
                printf("claim-verdict\t%s\tverdict\t%s\tMEASURED\tnote\tverdict-vocabulary-not-known-to-this-report-surfaced-verbatim-never-classified\n",
                       C->genhash, C->verdict);
            if (claim_verdict_disagrees(C->verdict))
                printf("claim-disagreement\t%s\tverdict\t%s\tDERIVED\tthe verdict names a disagreement between the claim's world model and the store (verbatim from the observation; the audit of the observation is the judge's own next run — this seat does not)\n",
                       C->genhash, C->verdict);
        } else {
            printf("claim-record\t%s\tversion\t%u\tclaim-sha\t-\top-from\t-\tNOT-RECORDED\tbound\tno-observation-row-judge-not-run-since-publish-or-its-run-disagreed-and-the-observation-kept-its-baseline (NOT 'none occurred')\n",
                   V->genhash, V->v);
        }
    }
    /* observation rows naming NO live generation: the record outlives the
     * store's snapshots (fxstore does not know the file) — kept and noted,
     * never dropped: a row is checkable against the timeline, not
     * authoritative over it. */
    for (unsigned k = 0; k < g_ncrows; k++) {
        crow_t *C = &g_crows[k];
        int live = 0;
        for (unsigned i = 0; i < g_nvers; i++)
            if (!strcmp(g_vers[i].genhash, C->genhash)) { live = 1; break; }
        if (live) continue;
        printf("claim-record\t%s\tversion\t%u\tclaim-sha\t%s\top-from\t%s\tMEASURED\tnote\tgeneration-not-in-live-timeline-pruned-or-foreign\n",
               C->genhash, C->version, C->sha, C->opfrom);
        if (claim_cls_known(C->verdict))
            printf("claim-verdict\t%s\tverdict\t%s\tMEASURED\n", C->genhash, C->verdict);
        else
            printf("claim-verdict\t%s\tverdict\t%s\tMEASURED\tnote\tverdict-vocabulary-not-known-to-this-report-surfaced-verbatim-never-classified\n",
                   C->genhash, C->verdict);
        if (claim_verdict_disagrees(C->verdict))
            printf("claim-disagreement\t%s\tverdict\t%s\tDERIVED\tthe verdict names a disagreement between the claim's world model and the store (verbatim from the observation; the audit of the observation is the judge's own next run — this seat does not)\n",
                   C->genhash, C->verdict);
    }

    /* ── the reconstruction: adjacent pairs, both inputs, the diff ────── */
    for (unsigned i = 1; i < g_nvers; i++) {
        version_t *A = &g_vers[i - 1], *B = &g_vers[i];
        if (A->cfg_read != 1 || B->cfg_read != 1) {
            printf("config-diff-summary\t%u\t%u\tnot-comparable\t%s\t%s\n", A->v, B->v,
                   A->cfg_read == 1 ? "input-readable" : (A->cfg_read < 0 ? "input-copy-missing" : "input-absent"),
                   B->cfg_read == 1 ? "input-readable" : (B->cfg_read < 0 ? "input-copy-missing" : "input-absent"));
            continue;
        }
        if (!strcmp(A->cfg_sha, B->cfg_sha)) {
            printf("config-diff-summary\t%u\t%u\tidentical\n", A->v, B->v);
            continue;
        }
        diff_pair(A, B);
    }

    /* ── the human summary ─────────────────────────────────────────────── */
    h("— summary —");
    h("store %s: %u published version(s), CURRENT %u%s.", g_store, g_nvers, cur_v,
      cur_v != newest ? " (NOT the newest — see the current-repoint event)" : "");
    unsigned n_act = 0, n_gh = 0;
    for (unsigned i = 0; i < g_nvers; i++) {
        if (strcmp(g_vers[i].genhash, "-")) n_act++;
        else n_gh++;
    }
    unsigned n_ok = 0, n_fa = 0, n_ip = 0, n_sd = 0;
    for (unsigned i = 0; i < g_nbl; i++) {
        if (!strcmp(g_bl[i].status, "ok")) n_ok++;
        else if (!strcmp(g_bl[i].status, "failed")) n_fa++;
        else if (!strcmp(g_bl[i].status, "in-progress")) n_ip++;
        else if (!strcmp(g_bl[i].status, "shutdown")) n_sd++;
    }
    h("generations with activation facts: %u; store-bootstrap snapshots (no generation facts): %u.",
      n_act, n_gh);
    if (!g_bl_present)
        h("boots: NO .bootlog — no boot has ever been recorded for this store.");
    else
        h(".bootlog LINES (not boots: an in-guest activation appends its own in-progress line, so these can exceed the boot count): %u line(s) — %u ok, %u failed, %u in-progress, %u shutdown.",
          g_nbl, n_ok, n_fa, n_ip, n_sd);
    h("automatic roll-forwards: %u row(s) in .recovery%s.", g_nrec,
      g_rec_present ? "" : " (no .recovery — none ever recorded)");
    {
        unsigned n_op = 0;
        for (unsigned i = 0; i < g_nvers; i++) {
            version_t *V = &g_vers[i];
            if (!strcmp(V->genhash, "-")) continue;
            int nearest = -1, match = -1;
            dup_targets(i, &nearest, &match);
            if (match >= 0 && match != nearest && !recrow_names(V->v)) n_op++;
        }
        if (cur_v != newest) n_op++;
        if (!g_op_present)
            h("operator interventions: %u DERIVED (a backward move or a stale CURRENT the records do not attribute).  NO .operator journal exists for this store: it predates fx-init ca9cb06, so a generation-plane intervention here is NOT durably recorded at all — the disjunction is the bound, never a verdict.", n_op);
        else
            h("operator interventions: %u MEASURED from the .operator journal (%u row(s); %u of them a refusal — see event/activation-refusal), plus %u DERIVED for what the journal CANNOT see (a bypass path or a store-side history it has no row for: backward moves / stale CURRENT it does not attribute — the disjunction is the bound, never a verdict).",
              g_nop, g_nop, (unsigned)op_count_refusals(), n_op);
    }
    if (!g_op_present)
        h("activation refusals: THIS REPORT CANNOT SAY (no .operator journal — this store predates fx-init ca9cb06 — and rt_effect at /run/fx/log.db is tmpfs; see bound/rt-log-tmpfs).  The class's absence-meaning is NOT-DURABLY-RECORDED again exactly here.");
    else
        h("activation refusals: %u MEASURED in the .operator journal (outcome failed:<rc> | refused | refused-config, out of %u row(s)) — a count of RECORDED refusals, never of attempts.  Absence in the retained journal means NONE-IN-THE-JOURNAL, not 'none occurred': a REFUSAL row is written by PID1's control handler alone (an fx-activate that refuses outside the handler is invisible — a direct exec records only a publish that REACHED COMMIT), `unverified` rows are AMBIGUITY not refusal, and root in-guest can forge or truncate the file exactly as it can .bootlog (bound/operator-journal-bounds).",
          (unsigned)op_count_refusals(), g_nop);
    {
        unsigned n_cov = 0, n_uncov = 0, n_ok = 0, n_cl = 0, n_sk = 0, n_dis = 0, n_unk = 0;
        for (unsigned i = 0; i < g_nvers; i++) {
            if (!strcmp(g_vers[i].genhash, "-")) continue;
            int seen = 0;
            for (unsigned j = 0; j < i; j++)
                if (!strcmp(g_vers[j].genhash, g_vers[i].genhash)) { seen = 1; break; }
            if (seen) continue;
            if (crow_find(g_vers[i].genhash)) n_cov++; else n_uncov++;
        }
        for (unsigned k = 0; k < g_ncrows; k++) {
            const char *v = g_crows[k].verdict;
            if (!strcmp(v, "ok")) n_ok++;
            else if (!strcmp(v, "claimless")) n_cl++;
            else if (!strcmp(v, "skipped")) n_sk++;
            else if (claim_verdict_disagrees(v)) n_dis++;
            else n_unk++;
        }
        if (!g_clob_present)
            h("claim records: NO observation — the judge seat has never run on this store; %u live generation(s) are uncovered (named NOT-RECORDED above): 'none occurred' is NOT derivable from nothing.", n_uncov);
        else
            h("claim records: %u row(s) in the observation — %u live generation(s) covered, %u NOT covered (named NOT-RECORDED above); verdicts ok %u, claimless %u (none-occurred, measured), skipped %u, disagreements %u%s.  A disagreement is a RECORD, not a reporter finding; the audit of the observation is the judge's own next run.",
              g_ncrows, n_cov, n_uncov, n_ok, n_cl, n_sk, n_dis,
              n_unk ? " (unknown verdict vocabulary: surfaced verbatim)" : "");
    }
    h("the reconstruction question — 'what changed between N and N+1, and from");
    h("which input?' — is answered by the config/config-line/config-diff records");
    h("above; pairs whose input is absent say which kind of absence.");
    if (g_findings)
        h("FINDINGS: %u (a finding marks where the record SHOULD show something and does not).", g_findings);
    else
        h("findings: none.");

    printf("verdict\t%s\n", g_findings ? "documented-with-findings" : "documented");
    return g_findings ? 1 : 0;
}
