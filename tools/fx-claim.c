/* tools/fx-claim.c — THE JUDGE SEAT of the baliveau harness (claim unit S1).
 *
 * SIBLING OF THE REPORTER (tools/fx-report.c) and the AUDIT
 * (tools/fx-audit.c), and it inherits the family's three properties (design
 * record §7.1): HOST-SIDE, AGENT-UNWRITABLE, and a function of OBSERVABLE
 * SYSTEM STATE.  Where the reporter asks *is it documented?* and the audit
 * asks *is it honest?*, this seat asks *does the claim hold?* — the FIRST
 * LANDABLE INSTANCE of the pre-registered-claim mechanism END TO END.
 *
 * DEPLOYMENT STOPGAP, LABELLED: the seat and the evaluator it shells both run
 * HOST-SIDE today.  The committed target is IN-GUEST (the qemu lane, x64 via
 * QBE through the le->Osier port).  Same lexicon, same policy, same claim
 * bytes, same record — only the evaluator's LOCATION differs, and the
 * location must never become a reason to shrink the language (the exact
 * error the round-2 revision exists to undo).
 *
 * WHAT IT JUDGES — the triple, assembled host-side PER GENERATION:
 *   the CLAIM     the two extraEtc rows the agent rode INTO the activation:
 *                 /etc/fx-claim.tsv (the row: claim, config-diff,
 *                 from_version, S_from — the agent's model of the world) and
 *                 /etc/fx-claim.le (the agent's free-LE argument).  They are
 *                 read from the generation dir the store retained
 *                 (<genhash>-system-generation/etc/ — the retained input,
 *                 gc-retained while a snapshot names it): IN the guest's
 *                 records, read from OUTSIDE.
 *   the VERDICT   ONE policy/eval_claim.py subprocess (stdout = the verdict):
 *                 the evaluation is FREE LE over the closed lexicon under the
 *                 frozen policy — THIS SEAT OWNS THE RECORD, NOT THE
 *                 REASONING.  The evaluator is never reimplemented here, and
 *                 its refusal names are passed through verbatim.
 *   the OUTCOME   the .operator terminal rows for the publish(es) that
 *                 landed this generation — ALL of them, activate AND
 *                 rollback (the writer's ok/refused-config rollback rows
 *                 name the target version they landed; init.zig:4013/4056
 *                 — the refs were re-measured at the S3 re-measure; note
 *                 that the SECOND member carries no colon of its own, the
 *                 form that let two earlier passes remap half a group):
 *                 a genhash can land at more than one version — + the
 *                 generation facts (the store's own account of what the
 *                 activation did).
 *
 * THE STORE IS NEVER REIMPLEMENTED: versions come from `fxstore timeline`,
 * facts from `fxstore facts <rel> --as-of N` (the fx-report.c facts pattern).
 * `le` is consumed as a dependency by the evaluator, never forked.
 *
 * THE BINDINGS — the comparisons round 1 ranked MOST LIKELY SILENTLY WRONG.
 * Each is stated with its direction; a wrong binding makes a disagreement
 * fire NEVER or ALWAYS, silently:
 *
 *   BINDING 1 (direction: STORE -> EVALUATOR).  --landed-config is the
 *     generation_config fact of the generation the claim RIDES IN, read from
 *     the store's own dump.  It is NEVER the claim row's S_from: fed the
 *     row's own value, the policy's differs guard (!landed_config(S_from))
 *     would be false for EVERY claim (landed == S_from always) and the
 *     vacuous-differs disagreement would fire ALWAYS; fed a constant, NEVER.
 *
 *   BINDING 2 (direction: ROW -> STORE TIMELINE).  The facts dumps handed to
 *     the evaluator are taken --as-of the version whose generation fact names
 *     the ROW's from_version — the world the claim claims to come from —
 *     NEVER --as-of the version the claim rides in (there the premises would
 *     be checked against the world the claim is about to change, and
 *     premise-false could never fire).
 *
 *   BINDING 3 (direction: STORE TIMELINE -> OPERATOR JOURNAL).  The row
 *     names its world by GENHASH (from_version); the .operator `activate`
 *     row that landed this generation names ITS world by VERSION
 *     (from-version).  The join is on CONTENT: the genhash live AT the op
 *     row's from-version (the timeline's own mapping) must BE the row's
 *     from_version.  A first-appearance join — resolve the genhash to the
 *     FIRST version naming it and compare version NUMBERS — breaks on any
 *     republish of the same genhash: a rollback or re-activation lands the
 *     identical bytes AGAIN at a higher version (the substrate adopts the
 *     existing dir), the op row's from-version names THAT landing, and the
 *     number join fired stale-world on an HONEST claim (measured on a real
 *     rollback store, round-2 review).
 *
 *     THE OUTCOME QUESTION SPANS ALL LANDINGS (round 3; the round-2 seat
 *     bound it to the FIRST landing's row alone and the round-2 review
 *     measured the escape: a generation that first landed behind a
 *     dhake-failed publish and later RE-LANDED ok — the operator's natural
 *     retry — answered verdict=skipped FOREVER, so the live, ok-published
 *     generation's claim was NEVER judged: a seat never called is
 *     indistinguishable from an absent seat).  The generation is a judged
 *     one when ANY terminal row landing this genhash — an `activate` row,
 *     or the writer's terminal `rollback` row (init.zig:4056 appends it
 *     when the rollback LANDED; a `fxctl rollback` publishes exactly as
 *     an activate does; the round-3 filter dropped those rows
 *     and a rollback-published generation was never judged, measured
 *     round-4) — has outcome `ok`; only when rows land it and NONE is ok
 *     is it SKIPPED — stated, never judged (the plan's risk-6 class:
 *     `dhake-failed` and `refused-config` LANDED their version —
 *     init.zig:3866/:3952/:4013, the config was refused after the publish
 *     committed — while `refused`/`unverified`/`failed:<rc>` name no
 *     landed version; no judgment either way).  The
 *     from-version cross-check itself binds the FIRST landing's ACTIVATE
 *     row — the claim's authoring context, see binding3_opfrom (a
 *     rollback row's from-version is the world the rollback moved FROM).
 *     A generation with
 *     no row at all (a publish outside the journal's reach) skips the
 *     cross-check, STATED on the record line, never silently.
 *
 *   BOUND (BINDINGS 1/2, stated): both canonicalize a generation to the
 *     FIRST version whose fact names its genhash, and judge the config sha
 *     THAT version's generation_config carries.  A comment-only
 *     re-activation keeps the genhash while re-asserting generation_config
 *     with the NEWER bytes' sha (the substrate adopts the existing dir and
 *     rewrites the retained config): the later sha is invisible to every
 *     later run.  The seat judges the bytes the claim originally rode
 *     against — the record line states version=N.
 *
 *   BOUND (THE OUTCOME GATE READS ONLY JOURNALED LANDINGS — DECISION B,
 *     round-5, stated here and as a `bound<TAB>` line on every run, never
 *     read): the seat judges a generation from its <store>/.operator rows
 *     ALONE.  The writer's OWN header (operator_journal.zig:174-183)
 *     enumerates landing moves that write NO row there and are NOT
 *     DETECTABLE from it: the AUTOMATIC .recovery roll-forward (a flapping
 *     machine rolls FORWARD to the newest ok-booted version via the SAME
 *     soft rollback — init.zig:1798 — re-landing the generation with no
 *     .operator row; the row lands in .recovery, which the AUDIT reads and
 *     which means AUTOMATIC — so this seat deliberately does NOT read it),
 *     a host-side `fxstore rollback`, `fxstore rollback --hard`, and a
 *     hand-edited store CURRENT.  DIRECTION: a claim generation first
 *     landed with a non-ok outcome and later RE-LANDED by one of these
 *     stays verdict=skipped while live and ok-booted — its claim is never
 *     judged, silently.  Stated, not resolved: reading .recovery as an
 *     operator landing would break the meaning the audit relies on.
 *
 * THE NAMED VERDICT CLASSES (one assertion, one message, one fixture each):
 *   ok                 the claim derives (the evaluator's verdict)
 *   <refusal name>     the evaluator refused BY NAME (hostile-compile,
 *                      head-forgery, premise-false, malformed-claim,
 *                      justified-not-derived, stale-lexicon/stale-policy,
 *                      pin-incomplete) — the reasoning is the evaluator's
 *   stale-world        BINDING 3 failed: the row's from_version is not the
 *                      world this activation actually came from
 *   not-a-claim        a claim row without its argument, or an empty row
 *                      file — LOUD: never read as claimless (extraEtc is a
 *                      convention, not a schema; an unrelated file must die
 *                      loudly, not silently vanish)
 *   no-claim           a claimless generation POST-enrollment — the §1a
 *                      gap-3 error is reading this absence as "none
 *                      occurred"; it keeps firing until acted on
 *   claimless          claimless AT the enrollment baseline (stated, not a
 *                      finding: the baseline records what the world was)
 *   skipped            no landing of this generation carries an outcome-ok
 *                      .operator row — no judgment
 *   verdict-rewritten  the OBS's recorded verdict for a generation differs
 *                      from the recomputed one (a tampered observation)
 *   claim-rewritten    the claim bytes of a PUBLISHED generation changed
 *                      under the same genhash (the claim rode in as
 *                      content; it does not rewrite) — or APPEARED under a
 *                      genhash the baseline recorded claimless (sha "-"):
 *                      the same rewrite, named
 *
 * THE OBSERVATION STORE: fx-audit's discipline VERBATIM (the
 * observation-store block of tools/fx-audit.c) — a plain text FILE,
 * <store>.fx-claim-obs by default (a SIBLING of the store), or --obs-dir
 * DIR.  A location INSIDE the store is REFUSED — the observation is host
 * memory and must not live on agent-reachable disk.  A FIRST-EVER run
 * ENROLS: it records what it sees and compares nothing (stated in the
 * output, never silent).  THE ENROLLMENT BOUNDARY is the obs file's
 * existence: drop it and every run re-enrolls, reading every absence as
 * none-occurred.  The observation is rewritten after enrollment, and after a
 * run with no OBS-COMPARISON finding (verdict-rewritten / claim-rewritten /
 * no-claim — the classes that are a disagreement WITH THE PREVIOUS
 * OBSERVATION keep it unrewritten, so a tampered observation reports on
 * every run until someone acts); a run with only JUDGMENT findings
 * (stale-world, refusals, not-a-claim, skipped) still records them — the
 * record of a refused claim is the record's purpose, and freezing it out
 * would silence exactly the runs that produced it.  --re-enroll resets the
 * baseline.  No wall-clock, no randomness: two runs over the same store
 * write byte-identical observations (gated).
 *
 * EXIT: 0 every generation coherent (ok / claimless / skipped, no
 * disagreement with the previous observation); 1 disagreement or refusal
 * found (named); 2 tool error (a broken invocation or an unreadable input —
 * never a silent does-not-derive).
 *
 * USAGE: fx-claim --store DIR [--policy FILE] [--obs-dir DIR]
 *                 [--fxstore BIN] [--re-enroll]
 */

#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include "dhall.h" /* sha256_hex (vendored dhall-c/sha256.c) */

#define LINE_MAX_ 8192
#define MAX_GENERATIONS 256
#define MAX_OP_ROWS 4096
#define MAX_FINDINGS 128

static const char *g_store = NULL;
static char g_store_abs[4096];
static const char *g_fxstore = NULL;
static const char *g_policy = NULL;     /* the compiled, pinned rule text */
static char g_lexicon[4096];            /* the policy's siblings */
static char g_evalpy[4096];
static char g_pins[4096];               /* may be absent: stated, never silent */
static int g_have_pins = 0;
static const char *g_obsdir = NULL;     /* --obs-dir (resolved) */
static char g_obsdef[4200];             /* the default obs path */
static int g_reenroll = 0;

static int g_have_obs = 0;
static int g_journal_absent = 0;
static char g_obs_store_[4096];          /* the store the read baseline is bound to */

/* ── loud failure / findings ─────────────────────────────────────────────── */

static void die(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    fputs("fx-claim: FAIL: ", stderr);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
    exit(2);
}

static void info(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    fputs("fx-claim: ", stdout);
    vfprintf(stdout, fmt, ap);
    fputc('\n', stdout);
    va_end(ap);
}

/* ── small utilities ─────────────────────────────────────────────────────── */

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
    size_t n = strlen(s) + 1;
    char *p = xmalloc(n);
    memcpy(p, s, n);
    return p;
}

/* every path that rides a shell command line is checked, then single-quoted
 * by sh_quote below — the seat shells fxstore and the evaluator only */
static void check_safe_path(const char *p, const char *what) {
    if (!p || !*p) die("%s: empty path", what);
    if (p[0] == '-') die("%s '%s' looks like an option, not a path", what, p);
    for (const char *c = p; *c; c++)
        if ((unsigned char)*c < 0x20 || *c == '\'')
            die("%s '%s' carries a character this seat refuses to put on a command line", what, p);
}

static char *sh_quote(const char *s) {
    size_t n = strlen(s) + 4;
    char *out = xmalloc(n);
    snprintf(out, n, "'%s'", s);
    return out;
}

/* read a whole file; absent=1 ONLY on ENOENT (an absent record is a STATE
 * here — a read ERROR is never silently read as absence) */
static char *read_file(const char *path, size_t *len, int *absent) {
    *absent = 0;
    *len = 0;
    FILE *f = fopen(path, "rb");
    if (!f) {
        if (errno == ENOENT) { *absent = 1; return NULL; }
        die("cannot read '%s': %s", path, strerror(errno));
    }
    size_t cap = 65536, n = 0;
    char *buf = xmalloc(cap);
    for (;;) {
        if (n + 4096 + 1 > cap) { cap *= 2; buf = xrealloc(buf, cap); }
        size_t r = fread(buf + n, 1, 4096, f);
        n += r;
        if (r == 0) {
            if (ferror(f)) die("cannot read '%s': %s", path, strerror(errno));
            break;
        }
    }
    fclose(f);
    buf[n] = 0;
    *len = n;
    return buf;
}

/* split into fields; the .operator row grammar is whitespace-separated ("<epoch>
 * <action> <arg> <outcome> <from|-> <to|-> <nonce|none>", operator_journal.zig),
 * the claim row is TAB-separated */
static size_t split_fields(char *line, char **f, size_t maxf, const char *seps) {
    size_t n = 0;
    char *save = NULL;
    for (char *tok = strtok_r(line, seps, &save); tok && n < maxf;
         tok = strtok_r(NULL, seps, &save))
        f[n++] = tok;
    return n;
}

/* ── shelling fxstore (the reporter's pattern: the seat that exists for
 *    exactly this; REUSED, never reimplemented) ──────────────────────────── */

static char *fxstore_capture(const char *args, int *rc) {
    char *cmd;
    char *qbin = sh_quote(g_fxstore);
    if (asprintf(&cmd, "%s %s", qbin, args) < 0) die("out of memory");
    free(qbin);
    FILE *p = popen(cmd, "r");
    if (!p) die("cannot popen fxstore (%s)", strerror(errno));
    size_t cap = 65536, len = 0;
    char *buf = xmalloc(cap);
    char line[LINE_MAX_];
    while (fgets(line, sizeof line, p)) {
        size_t ll = strlen(line);
        if (len + ll + 1 > cap) { while (len + ll + 1 > cap) cap *= 2; buf = xrealloc(buf, cap); }
        memcpy(buf + len, line, ll + 1);
        len += ll;
    }
    int st = pclose(p);
    *rc = WIFEXITED(st) ? WEXITSTATUS(st) : -1;
    free(cmd);
    if (len == 0) buf[0] = 0;
    return buf;
}

static char **fxstore_lines(const char *args, size_t *n) {
    int rc;
    char *out = fxstore_capture(args, &rc);
    if (rc != 0)
        die("'fxstore %s' failed (exit %d) — cannot read the store's records", args, rc);
    char **lines = NULL; size_t cnt = 0;
    char *save = NULL;
    for (char *tok = strtok_r(out, "\n", &save); tok; tok = strtok_r(NULL, "\n", &save)) {
        lines = realloc(lines, (cnt + 1) * sizeof *lines);
        if (!lines) die("out of memory");
        lines[cnt++] = xstrdup(tok);
    }
    free(out);
    *n = cnt;
    return lines;
}

/* ── the store's account: versions, generations, the operator journal ────── */

static unsigned g_vers[MAX_GENERATIONS];
static size_t g_nvers = 0;
static char g_vgenhash[MAX_GENERATIONS][65]; /* version -> genhash (first row wins) */

typedef struct {
    char genhash[65];
    unsigned version;        /* FIRST version whose generation fact names it */
    char cfg_sha[65];        /* BINDING 1: the landed config, from the store */
    char *tsv;    size_t ntsv;   int tsv_absent;
    char *le;     size_t nle;    int le_absent;
    char claimsha[65];       /* sha256(tsv bytes || le bytes): the CLAIM's identity */
    char cls[64];            /* the verdict class (see the named classes) */
    char opfrom[32];         /* BINDING 3: the .operator row's from-version */
    int  op_state;           /* 0 no-ok-row, 1 bound (ok row), 2 skipped-outcome */
    char opnote[160];
    char *evalout;           /* the evaluator's stdout, verbatim (the VERDICT record) */
    int  evaled;
} gen_t;

static gen_t g_gen[MAX_GENERATIONS];
static size_t g_ngen = 0;

typedef struct { char action[32]; char outcome[64]; char fromv[32]; char tov[32]; } oprow_t;
static oprow_t g_op[MAX_OP_ROWS];
static size_t g_nop = 0;

static int gen_find(const char *genhash) {
    for (size_t i = 0; i < g_ngen; i++)
        if (!strcmp(g_gen[i].genhash, genhash)) return (int)i;
    return -1;
}

/* BINDING 2's resolution (direction: ROW -> TIMELINE): the row names a
 * generation; the timeline answers with the version that first carried it */
static long resolve_from_version(const char *from_version) {
    for (size_t i = 0; i < g_nvers; i++)
        if (!strcmp(g_vgenhash[i], from_version)) return (long)g_vers[i];
    return -1;
}

/* ── the findings ────────────────────────────────────────────────────────── */

typedef struct { char cls[64]; char gen[80]; char detail[1024]; } finding_t;
static finding_t g_findings[MAX_FINDINGS];
static size_t g_nfindings = 0;

static void add_finding(const char *cls, const char *gen, const char *fmt, ...) {
    if (g_nfindings >= MAX_FINDINGS) die("too many findings (cap %d)", MAX_FINDINGS);
    finding_t *f = &g_findings[g_nfindings++];
    snprintf(f->cls, sizeof f->cls, "%s", cls);
    snprintf(f->gen, sizeof f->gen, "%s", gen);
    va_list ap; va_start(ap, fmt);
    vsnprintf(f->detail, sizeof f->detail, fmt, ap);
    va_end(ap);
}

/* a class that blocks the observation rewrite: the disagreement WITH THE
 * PREVIOUS OBSERVATION (see the header's rewrite rule) */
static int cls_blocks_obs(const char *cls) {
    return !strcmp(cls, "verdict-rewritten") || !strcmp(cls, "claim-rewritten")
        || !strcmp(cls, "no-claim");
}

/* the genhash live at version v, by the timeline's own mapping (NULL when
 * the version carries no generation fact — the store's own setup) */
static const char *genhash_at_version(unsigned v) {
    for (size_t i = 0; i < g_nvers; i++)
        if (g_vers[i] == v && g_vgenhash[i][0]) return g_vgenhash[i];
    return NULL;
}

/* does this .operator row's to-version LAND this generation?  The ALL-
 * LANDINGS rule of the round-3 op binding: a genhash is live at every
 * version whose snapshot names it (a rollback or a retry of the same config
 * re-lands the identical bytes), so EVERY terminal row whose to-version
 * carries the genhash is a row of this generation's landing — not only the
 * first appearance's row (the round-2 binding, which skipped a re-landed-ok
 * generation forever; measured, round-2 review).  Round 4: the row's ACTION
 * is checked by the caller (activate, or the writer's terminal rollback
 * rows — ok/refused-config name the landed target, init.zig:4013/4056).
 * A '-' or unparsable to-version (the writer's `refused`/`unverified`/
 * `failed:<rc>` rows, and every `shutdown` row) lands nothing. */
static int row_lands(const char *tov, const gen_t *G) {
    char *end = NULL;
    unsigned long v = strtoul(tov, &end, 10);
    if (end == tov || *end) return 0;
    for (size_t i = 0; i < g_nvers; i++)
        if (g_vers[i] == (unsigned)v)
            return g_vgenhash[i][0] && !strcmp(g_vgenhash[i], G->genhash);
    return 0;
}

/* ── BINDING 3 (direction: STORE TIMELINE -> OPERATOR JOURNAL) ───────────── */
/* The row names its world by GENHASH; the .operator row names the world the
 * activation moved from by VERSION.  The join is on CONTENT: the genhash
 * live AT the op row's from-version must BE the row's from_version — a
 * first-appearance NUMBER join fires stale-world on honest claims whenever
 * a genhash lands at more than one version (a rollback or re-activation;
 * measured, round-2 review; see the header).  On one line in main() sits
 * the single call to this check: the gate's mutant deletes exactly that
 * line and the stale-world arm's answer changes — the check can fail.
 * THE OP ROW THIS CHECK READS IS THE FIRST LANDING'S ACTIVATE ROW (the
 * call site binds
 * it): the claim rode into the generation's bytes when they FIRST landed,
 * so its from_version names the world live THEN — the claim's authoring
 * context.  Round 4: ACTIVATE only — a rollback row's from-version is the
 * world the rollback moved FROM, and a rollback returning to the first
 * landing's own version would bind that pre-rollback world (a false-fail).
 * MEASURED TRAP (round-2 review, probe 1): binding to a LATER
 * ok row's from-version instead false-fails the honest claim after a
 * failed-then-retried activation — the retry's from-world IS the claim's
 * own generation.  The OUTCOME gate lives at the call site too and spans
 * ALL landings: a generation is judged when ANY landing's row is ok; this
 * check is reached at all only then (or with no row, the stated skip).  A
 * version with no row skips the check, stated on the record line, never
 * silently. */
static void binding3_opfrom(gen_t *G, const char *from_genhash, int *stale, char *why, size_t cap) {
    if (*stale) return;                 /* an earlier binding already named it */
    if (!from_genhash) return;          /* the row never parsed: the evaluator refuses it */
    if (G->op_state == 0) {             /* no row for this publish: skipped, stated */
        snprintf(G->opnote, sizeof G->opnote, "no-operator-row-cross-check-skipped");
        return;
    }
    if (!G->opfrom[0]) {                /* ok at a LATER landing, no row for the
                                         * FIRST: nothing describes the authoring
                                         * landing — skipped, stated, never
                                         * rebound to the later row (the trap) */
        snprintf(G->opnote, sizeof G->opnote,
                 "no-operator-row-for-first-landing-cross-check-skipped");
        return;
    }
    if (!strcmp(G->opfrom, "-")) {      /* a first activation: no previous world */
        *stale = 1;
        snprintf(why, cap,
                 "the activation that landed version %u came from no recorded version "
                 "(from-version '-'), but the claim's from_version '%s' names a generation — "
                 "the claim names a previous world that did not exist",
                 G->version, from_genhash);
        return;
    }
    char *end = NULL;
    unsigned long opv = strtoul(G->opfrom, &end, 10);
    if (!end || *end) {                 /* unparsable row field: skipped, stated */
        snprintf(G->opnote, sizeof G->opnote, "operator-from-unparsable-cross-check-skipped");
        return;
    }
    const char *live = genhash_at_version((unsigned)opv);
    if (!live) {                        /* nothing was live there: no world to come from */
        *stale = 1;
        snprintf(why, cap,
                 "the .operator row for version %u records from-version %s, which carries no "
                 "generation — the claim's from_version '%s' names a world this activation "
                 "did not come from",
                 G->version, G->opfrom, from_genhash);
        return;
    }
    if (strcmp(live, from_genhash)) {
        *stale = 1;
        snprintf(why, cap,
                 "the claim's from_version '%s' names a different world than the one this "
                 "activation came from: the .operator row for version %u records from-version "
                 "%s, and the generation live there is '%s' — the claim diffs from a world "
                 "this activation did not come from",
                 from_genhash, G->version, G->opfrom, live);
    }
}

/* ── the observation store (fx-audit's discipline, verbatim) ─────────────── */

typedef struct {
    char genhash[65];
    unsigned version;
    char verdict[64];
    char sha[65];            /* '-' when the generation was claimless */
    char opfrom[32];
} obs_t;

static obs_t g_obs[MAX_GENERATIONS];
static size_t g_nobs = 0;

static void obs_path_for(char *out, size_t cap) {
    if (g_obsdir) {
        char key[65];
        char kb[8192];
        snprintf(kb, sizeof kb, "store:%s", g_store_abs);
        sha256_hex(kb, strlen(kb), key);
        key[16] = 0;
        snprintf(out, cap, "%s/%s.fx-claim-obs", g_obsdir, key);
        return;
    }
    snprintf(out, cap, "%s", g_obsdef);
}

static void obs_read(void) {
    char path[4096];
    obs_path_for(path, sizeof path);
    FILE *f = fopen(path, "r");
    if (!f) {
        if (errno == ENOENT) return; /* first-ever run: enroll */
        die("cannot open observation '%s': %s", path, strerror(errno));
    }
    char line[LINE_MAX_];
    line[0] = 0;
    if (!fgets(line, sizeof line, f) || strcmp(line, "fx-claim-observation 1\n") != 0)
        die("observation '%s' is not format 1 — an observation this seat did not write "
            "is not a baseline; re-establish it with --re-enroll", path);
    int have_store = 0;
    while (fgets(line, sizeof line, f)) {
        if (!strncmp(line, "store ", 6)) {
            char v[4096];
            if (sscanf(line + 6, "%4095s", v) != 1) die("bad store line in observation '%s'", path);
            snprintf(g_obs_store_, sizeof g_obs_store_, "%s", v);
            have_store = 1;
            continue;
        }
        if (!strncmp(line, "claim ", 6)) {
            if (g_nobs >= MAX_GENERATIONS) die("observation has too many generations");
            obs_t *o = &g_obs[g_nobs];
            /* format: claim <genhash> version <N> verdict <cls> claim-sha <sha> op-from <v|-> */
            char sha[80], opf[80];
            if (sscanf(line + 6, "%64s version %u verdict %63s claim-sha %79s op-from %79s",
                       o->genhash, &o->version, o->verdict, sha, opf) != 5)
                die("bad claim line in observation '%s': %s", path, line);
            snprintf(o->sha, sizeof o->sha, "%s", sha);
            snprintf(o->opfrom, sizeof o->opfrom, "%s", opf);
            g_nobs++;
            continue;
        }
        if (!strcmp(line, "end\n")) {
            if (!have_store)
                die("observation '%s' records no store — a baseline bound to no store "
                    "is not a baseline", path);
            /* the baseline is bound to ONE store: the sibling-file layout
             * makes a carried copy possible, and a baseline for another path
             * is exactly the confusion the store line exists to prevent */
            if (strcmp(g_obs_store_, g_store_abs) != 0)
                die("observation '%s' is the baseline of store '%s', not of '%s' — an "
                    "observation carried between stores proves nothing; delete it or --re-enroll",
                    path, g_obs_store_, g_store_abs);
            g_have_obs = 1;
            fclose(f);
            return;
        }
        die("unknown line in observation '%s': %s", path, line);
    }
    die("observation '%s' has no end marker (torn write?)", path);
}

static void obs_write(void) {
    char path[4096];
    obs_path_for(path, sizeof path);
    char tmp[4200];
    snprintf(tmp, sizeof tmp, "%s.tmp", path);
    FILE *f = fopen(tmp, "w");
    if (!f && g_obsdir) {
        /* first use of an explicit --obs-dir: create it (EEXIST is fine) */
        mkdir(g_obsdir, 0755);
        f = fopen(tmp, "w");
    }
    if (!f) die("cannot write observation '%s': %s", tmp, strerror(errno));
    fprintf(f, "fx-claim-observation 1\n");
    fprintf(f, "store %s\n", g_store_abs);
    /* store generations in version order, then generations the store pruned
     * that the observation still carries (in observation order) — a function
     * of the store's bytes and the previous observation alone, so two runs
     * over the same store write byte-identical observations (gated) */
    for (size_t i = 0; i < g_ngen; i++) {
        gen_t *G = &g_gen[i];
        fprintf(f, "claim %s version %u verdict %s claim-sha %s op-from %s\n",
                G->genhash, G->version, G->cls,
                G->tsv_absent ? "-" : G->claimsha,
                (G->op_state == 1 && G->opfrom[0]) ? G->opfrom : "-");
    }
    for (size_t i = 0; i < g_nobs; i++) {
        obs_t *o = &g_obs[i];
        int live = 0;
        for (size_t j = 0; j < g_ngen; j++)
            if (!strcmp(g_gen[j].genhash, o->genhash)) { live = 1; break; }
        if (live) continue;
        fprintf(f, "claim %s version %u verdict %s claim-sha %s op-from %s\n",
                o->genhash, o->version, o->verdict, o->sha, o->opfrom);
    }
    fprintf(f, "end\n");
    fflush(f);
    if (ferror(f)) die("cannot write observation '%s'", tmp);
    fclose(f);
    if (rename(tmp, path) != 0) die("cannot rename '%s' -> '%s': %s", tmp, path, strerror(errno));
}

static obs_t *obs_find(const char *genhash) {
    for (size_t i = 0; i < g_nobs; i++)
        if (!strcmp(g_obs[i].genhash, genhash)) return &g_obs[i];
    return NULL;
}

/* ── the evaluator: ONE subprocess; the reasoning is never reimplemented ─── */

/* the per-relation dumps --as-of V' (BINDING 2) into dir.  The evaluator's
 * dump grammar is `relation<TAB>col...` (the frozen table it reads is keyed
 * by relation name); `fxstore facts <rel>` prints the COLUMNS only, so the
 * seat prefixes each line with the relation it asked for — a formatting
 * seam, not a reimplementation: the bytes after the prefix are fxstore's. */
static void write_facts_dumps(unsigned as_of, const char *dir) {
    static const char *const RELS[] = { "generation_config", "install", "provides" };
    for (size_t r = 0; r < sizeof RELS / sizeof RELS[0]; r++) {
        char args[8192], path[4200];
        snprintf(args, sizeof args, "facts %s --as-of %u --store '%s'", RELS[r], as_of, g_store_abs);
        int rc;
        char *out = fxstore_capture(args, &rc);
        if (rc != 0)
            die("facts %s --as-of %u failed (exit %d) — cannot assemble the claim's world",
                RELS[r], as_of, rc);
        snprintf(path, sizeof path, "%s/%s.dump", dir, RELS[r]);
        FILE *f = fopen(path, "w");
        if (!f) die("cannot write facts dump '%s': %s", path, strerror(errno));
        char *save = NULL;
        for (char *tok = strtok_r(out, "\n", &save); tok; tok = strtok_r(NULL, "\n", &save))
            fprintf(f, "%s\t%s\n", RELS[r], tok);
        fclose(f);
        free(out);
    }
}

/* run policy/eval_claim.py once; hand back the captured stdout (the VERDICT
 * record, verbatim) and the exit code.  The claim is read FROM THE
 * GENERATION DIR (the same bytes the record is about), the landed config is
 * BINDING 1 (the store's own fact, never the row's S_from), the dumps are
 * BINDING 2.  The evaluator's stderr is left on the seat's stderr: a tool
 * error names itself there. */
static int run_evaluator(const gen_t *G, const char *tsxpath, const char *lepath,
                         const char *dumpdir, char **out) {
    char *qeval = sh_quote(g_evalpy);
    char *qtsv  = sh_quote(tsxpath);
    char *qle   = sh_quote(lepath);
    char *qlex  = sh_quote(g_lexicon);
    char *qpol  = sh_quote(g_policy);
    char *qland = sh_quote(G->cfg_sha);
    char *qdump = sh_quote(dumpdir);
    char qpins[4400] = "";
    if (g_have_pins) {
        char *q = sh_quote(g_pins);
        snprintf(qpins, sizeof qpins, " --pins %s", q);
        free(q);
    }
    char *cmd;
    if (asprintf(&cmd,
                 "python3 %s --claim %s --le %s --lexicon %s --policy %s%s "
                 "--landed-config %s "
                 "--facts %s/generation_config.dump --facts %s/install.dump "
                 "--facts %s/provides.dump",
                 qeval, qtsv, qle, qlex, qpol, qpins, qland, qdump, qdump, qdump) < 0)
        die("out of memory");
    free(qeval); free(qtsv); free(qle); free(qlex); free(qpol); free(qland); free(qdump);

    FILE *p = popen(cmd, "r");
    if (!p) die("cannot run the evaluator (%s)", strerror(errno));
    size_t cap = 16384, len = 0;
    char *buf = xmalloc(cap);
    char line[LINE_MAX_];
    while (fgets(line, sizeof line, p)) {
        size_t ll = strlen(line);
        if (len + ll + 1 > cap) { while (len + ll + 1 > cap) cap *= 2; buf = xrealloc(buf, cap); }
        memcpy(buf + len, line, ll + 1);
        len += ll;
    }
    int st = pclose(p);
    int rc = WIFEXITED(st) ? WEXITSTATUS(st) : -1;
    free(cmd);
    *out = buf;
    return rc;
}

/* parse the evaluator's stdout for its verdict line; the class is the
 * evaluator's OWN name, verbatim — the seat never paraphrases the reasoning */
static void verdict_class(const char *evalout, int rc, char *cls, size_t cap) {
    const char *verdict = NULL;
    for (const char *p = evalout; p && *p;) {
        const char *eol = strchr(p, '\n');
        size_t ll = eol ? (size_t)(eol - p) : strlen(p);
        if (ll >= 8 && !strncmp(p, "verdict\t", 8)) verdict = p;
        p = eol ? eol + 1 : p + ll;
    }
    if (rc == 0) {
        if (!verdict || strncmp(verdict, "verdict\tderives", 15))
            die("the evaluator exited 0 but its stdout carries no 'verdict<TAB>derives' line — "
                "an unparsable verdict is a tool error, never a silent derives");
        snprintf(cls, cap, "ok");
        return;
    }
    if (rc == 1) {
        if (!verdict || strncmp(verdict, "verdict\trefused\t", 16))
            die("the evaluator refused (exit 1) but its stdout carries no "
                "'verdict<TAB>refused<TAB>name' line — an unnamed refusal is a tool error, "
                "never a silent one");
        const char *name = verdict + 16;
        const char *eol = strchr(name, '\n');
        size_t ll = eol ? (size_t)(eol - name) : strlen(name);
        if (ll == 0 || ll >= cap) die("the evaluator's refusal name is empty or overlong");
        memcpy(cls, name, ll);
        cls[ll] = 0;
        return;
    }
    die("the evaluator exited %d — a tool error is infrastructure, not a verdict; "
        "its stderr names the cause", rc);
}

/* ── usage / main ────────────────────────────────────────────────────────── */

static void usage(FILE *out) {
    fputs(
"fx-claim --store DIR [--policy FILE] [--obs-dir DIR] [--fxstore BIN] [--re-enroll]\n"
"\n"
"  --store DIR     the fxstore to judge (required)\n"
"  --policy FILE   the compiled, pinned policy rule text (default\n"
"                  $FX_CLAIM_POLICY, else policy/claims-policy.dl); the agent\n"
"                  lexicon, the evaluator and the pin file are its SIBLINGS\n"
"                  (claims-lexicon.ini / eval_claim.py / PINS)\n"
"  --obs-dir DIR   observation dir (default: the sibling FILE <store>.fx-claim-obs);\n"
"                  a location INSIDE the store is refused — host memory does not\n"
"                  live on agent-reachable disk\n"
"  --fxstore BIN   the fxstore binary (default $FXSTORE_BIN, else fxstore on PATH)\n"
"  --re-enroll     accept the current state as the new baseline\n", out);
}

int main(int argc, char **argv) {
    const char *obsdir_arg = NULL;
    const char *pol_arg = NULL;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--store") && i + 1 < argc) g_store = argv[++i];
        else if (!strncmp(argv[i], "--store=", 8)) g_store = argv[i] + 8;
        else if (!strcmp(argv[i], "--policy") && i + 1 < argc) pol_arg = argv[++i];
        else if (!strncmp(argv[i], "--policy=", 9)) pol_arg = argv[i] + 9;
        else if (!strcmp(argv[i], "--obs-dir") && i + 1 < argc) obsdir_arg = argv[++i];
        else if (!strncmp(argv[i], "--obs-dir=", 10)) obsdir_arg = argv[i] + 10;
        else if (!strcmp(argv[i], "--fxstore") && i + 1 < argc) g_fxstore = argv[++i];
        else if (!strncmp(argv[i], "--fxstore=", 10)) g_fxstore = argv[i] + 10;
        else if (!strcmp(argv[i], "--re-enroll")) g_reenroll = 1;
        else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) { usage(stdout); return 0; }
        else { fprintf(stderr, "fx-claim: unknown arg '%s'\n", argv[i]); usage(stderr); return 2; }
    }
    if (!g_store) { fprintf(stderr, "fx-claim: --store is required\n"); usage(stderr); return 2; }
    check_safe_path(g_store, "--store");
    if (pol_arg) check_safe_path(pol_arg, "--policy");
    if (obsdir_arg) check_safe_path(obsdir_arg, "--obs-dir");
    if (!g_fxstore) {
        const char *fb = getenv("FXSTORE_BIN");
        g_fxstore = (fb && *fb) ? fb : "fxstore";
    }
    check_safe_path(g_fxstore, "--fxstore");
    if (!realpath(g_store, g_store_abs))
        die("cannot resolve --store '%s': %s", g_store, strerror(errno));

    /* the policy: --policy, else $FX_CLAIM_POLICY, else the repo layout's
     * policy/claims-policy.dl — named when none resolves, never guessed */
    if (!pol_arg) {
        const char *env = getenv("FX_CLAIM_POLICY");
        if (env && *env) pol_arg = env;
        else pol_arg = "policy/claims-policy.dl";
    }
    char pol_abs[4096];
    if (!realpath(pol_arg, pol_abs))
        die("cannot resolve the policy '%s': %s (pass --policy, set $FX_CLAIM_POLICY, "
            "or run from the repo root)", pol_arg, strerror(errno));
    g_policy = pol_abs;
    char poldir[4096];
    snprintf(poldir, sizeof poldir, "%s", g_policy);
    char *slash = strrchr(poldir, '/');
    if (!slash) die("the policy path has no directory: %s", g_policy);
    *slash = 0;
    snprintf(g_lexicon, sizeof g_lexicon, "%s/claims-lexicon.ini", poldir);
    snprintf(g_evalpy,  sizeof g_evalpy,  "%s/eval_claim.py",      poldir);
    snprintf(g_pins,    sizeof g_pins,    "%s/PINS",               poldir);
    struct stat sb;
    if (stat(g_lexicon, &sb) != 0)
        die("no agent lexicon at '%s' (the policy's sibling) — the closed lexicon IS the boundary",
            g_lexicon);
    if (stat(g_evalpy, &sb) != 0)
        die("no evaluator at '%s' (the policy's sibling) — the seat shells it, never "
            "reimplements it", g_evalpy);
    g_have_pins = (stat(g_pins, &sb) == 0); /* absent pins: stated in the header line */

    /* the observation location: default the SIBLING FILE <store>.fx-claim-obs;
     * --obs-dir puts the keyed file there instead.  INSIDE the store is
     * refused — verbatim the audit's rule (agent-reachable disk). */
    if (!obsdir_arg) {
        snprintf(g_obsdef, sizeof g_obsdef, "%s.fx-claim-obs", g_store_abs);
    } else {
        char abs[8192];
        if (!realpath(obsdir_arg, abs)) {
            char parent[4096];
            snprintf(parent, sizeof parent, "%s", obsdir_arg);
            char *ps = strrchr(parent, '/');
            const char *leaf = obsdir_arg;
            if (ps && ps != parent) { *ps = 0; leaf = ps + 1; }
            char pabs[4096];
            if (!realpath(parent[0] ? parent : "/", pabs))
                die("cannot resolve --obs-dir parent '%s': %s", parent, strerror(errno));
            snprintf(abs, sizeof abs, "%s/%s", pabs, leaf);
        }
        size_t sl = strlen(g_store_abs);
        if (!strncmp(abs, g_store_abs, sl) && (abs[sl] == '/' || abs[sl] == 0))
            die("--obs-dir '%s' is INSIDE the store '%s' — the observation is host memory "
                "and must not live on agent-reachable disk", obsdir_arg, g_store_abs);
        g_obsdir = xstrdup(abs);
    }

    printf("fx-claim: store %s (fxstore %s)\n", g_store_abs, g_fxstore);
    printf("fx-claim: policy %s; lexicon %s; pins %s\n", g_policy, g_lexicon,
           g_have_pins ? g_pins : "none (an unpinned run — stated, never silent)");
    {
        char op[4096];
        obs_path_for(op, sizeof op);
        printf("fx-claim: observation %s\n", op);
    }
    printf("fx-claim: bound: the evaluator runs HOST-SIDE — a deployment stopgap, labelled: "
           "same lexicon, same policy, same claim bytes, same record; the committed target is "
           "in-guest (the qemu lane, x64 via QBE)\n");
    printf("fx-claim: bound: the judgment's OUTCOME gate spans ALL landings of a genhash (a "
           "rollback or a retry re-lands it): the generation is judged when ANY landing's "
           "terminal .operator row — an activate row, or the writer's ok/refused-config "
           "rollback row naming its landed target — is outcome ok, and skipped only when "
           "none is; rows of any OTHER action land nothing, so a FUTURE writer action that "
           "lands versions must be added to the filter by name (a silent never-judged "
           "generation) — and the OUTCOME vocabulary is read by NAME too (strcmp \"ok\"): a "
           "FUTURE outcome name meaning 'landed fine' silently counts not-ok, the same "
           "residual; the "
           "from-version cross-check binds the FIRST landing's ACTIVATE row — the claim's "
           "authoring context (plan risk 6 for the skipped class)\n");
    printf("bound\tunjournaled-landings\tthe OUTCOME gate reads only <store>/.operator (JOURNALED landings); the writer's own header (operator_journal.zig:174-183) enumerates landing moves that write NO row there and are NOT DETECTABLE from it, NOT read BY DESIGN (DECISION B, round-5): the AUTOMATIC .recovery roll-forward (a flapping machine rolls FORWARD to the newest ok-booted version via the SAME soft rollback — init.zig:1798 — the row lands in .recovery ONLY, which the AUDIT reads and which means AUTOMATIC), a host-side `fxstore rollback`, `fxstore rollback --hard`, and a hand-edited store CURRENT.  DIRECTION: a claim generation first landed with a non-ok outcome and later RE-LANDED by one of these stays verdict=skipped while live and ok-booted — its claim is never judged, silently.  Stated, never read: .recovery's AUTOMATIC meaning is the audit's\n");

    /* ── read the store (fxstore's own surface; never reimplemented) ─────── */
    {
        char args[4096];
        snprintf(args, sizeof args, "timeline --store '%s'", g_store_abs);
        size_t n = 0;
        char **lines = fxstore_lines(args, &n);
        for (size_t i = 0; i < n; i++) {
            unsigned v;
            if (sscanf(lines[i], " %u", &v) == 1) {
                if (g_nvers >= MAX_GENERATIONS)
                    die("timeline has more than %d versions — raise the cap or prune (gc --retain)",
                        MAX_GENERATIONS);
                g_vers[g_nvers++] = v;
            }
        }
        free(lines);
        for (size_t i = 0; i + 1 < g_nvers; i++)   /* ascending; enforce it */
            for (size_t j = i + 1; j < g_nvers; j++)
                if (g_vers[j] < g_vers[i]) { unsigned t = g_vers[i]; g_vers[i] = g_vers[j]; g_vers[j] = t; }
        if (!g_nvers) die("store %s has no published snapshot", g_store_abs);
    }
    for (size_t i = 0; i < g_nvers; i++) {
        char args[8192];
        snprintf(args, sizeof args, "facts generation --as-of %u --store '%s'", g_vers[i], g_store_abs);
        size_t n = 0;
        char **lines = fxstore_lines(args, &n);
        g_vgenhash[i][0] = 0;
        if (n >= 1) {                              /* first row wins; stated */
            char *f[8];
            size_t nf = split_fields(lines[0], f, 8, "\t\r\n");
            if (nf >= 1) snprintf(g_vgenhash[i], 65, "%s", f[0]);
        }
        free(lines);
    }

    /* the unique generations, in first-appearance order (a republish of live
     * content lands the SAME genhash at a new version — the triple is per
     * GENERATION, and the first version is BINDING 1/2's canonical one and
     * the FIRST LANDING whose .operator row BINDING 3 binds; the OUTCOME
     * question at the judge branch spans ALL landings of the genhash).
     * A version carrying NO generation fact is the store's own setup
     * (activate_paths publishes srcstore versions before any activation):
     * nothing landed there, so there is nothing to judge — skipped and
     * counted, never silently. */
    size_t n_setup = 0;
    for (size_t i = 0; i < g_nvers; i++) {
        if (!g_vgenhash[i][0]) { n_setup++; continue; }
        if (gen_find(g_vgenhash[i]) >= 0) continue;
        if (g_ngen >= MAX_GENERATIONS) die("more than %d generations — raise the cap", MAX_GENERATIONS);
        gen_t *G = &g_gen[g_ngen++];
        memset(G, 0, sizeof *G);
        snprintf(G->genhash, sizeof G->genhash, "%s", g_vgenhash[i]);
        G->version = g_vers[i];
    }

    /* BINDING 1: the landed config comes from the store's own dump */
    for (size_t i = 0; i < g_ngen; i++) {
        gen_t *G = &g_gen[i];
        char args[8192];
        snprintf(args, sizeof args, "facts generation_config --as-of %u --store '%s'",
                 G->version, g_store_abs);
        size_t n = 0;
        char **lines = fxstore_lines(args, &n);
        int found = 0;
        for (size_t j = 0; j < n && !found; j++) {  /* first row wins, like the reporter */
            char *f[8];
            size_t nf = split_fields(lines[j], f, 8, "\t\r\n");
            if (nf >= 3 && !strcmp(f[0], G->genhash)) {
                snprintf(G->cfg_sha, sizeof G->cfg_sha, "%s", f[1]);
                found = 1;
            }
        }
        free(lines);
        if (!found)
            die("generation %s (version %u) names no generation_config fact — without the "
                "store's own account of the landed config the differs guard cannot bind",
                G->genhash, G->version);
    }

    /* the .operator journal: read once, parsed to its DATA rows (lines
     * starting with a digit — the writer's own count rule) */
    {
        char path[4200];
        snprintf(path, sizeof path, "%s/.operator", g_store_abs);
        size_t n; int absent;
        char *bytes = read_file(path, &n, &absent);
        g_journal_absent = absent;
        if (!absent) {
            char *save = NULL;
            for (char *tok = strtok_r(bytes, "\n", &save); tok;
                 tok = strtok_r(NULL, "\n", &save)) {
                if (g_nop >= MAX_OP_ROWS) die(".operator has more than %d rows — raise the cap or prune (the newest rows — the re-landings — live at the tail; a silent drop would hide exactly them, measured round-4)", MAX_OP_ROWS);
                if (!(tok[0] >= '0' && tok[0] <= '9')) continue; /* header: skipped */
                char *f[8];
                size_t nf = split_fields(tok, f, 8, " \t\r\n");
                if (nf < 7) continue;                        /* not a data row */
                oprow_t *o = &g_op[g_nop++];
                snprintf(o->action,  sizeof o->action,  "%s", f[1]);
                snprintf(o->outcome, sizeof o->outcome, "%s", f[3]);
                snprintf(o->fromv,   sizeof o->fromv,   "%s", f[4]);
                snprintf(o->tov,     sizeof o->tov,     "%s", f[5]);
            }
        }
        free(bytes);
    }

    obs_read();
    /* THE ENROLLMENT BOUNDARY (one expression, one line — the gate's mutant
     * replaces exactly it): the first-ever run records what it sees and
     * compares nothing; every later run compares.  Dropping the boundary is
     * the §1a gap-3 error: "not recorded" read as "none occurred" (gated). */
    int enroll = !g_have_obs || g_reenroll;

    if (g_journal_absent)
        info("bound: no .operator — this store predates the journal (fx-init ca9cb06); "
             "the from-version cross-check is skipped, stated");
    if (n_setup)
        info("bound: %zu version(s) carry no generation fact (the store's own setup, before "
             "any activation) — skipped, stated", n_setup);

    /* ── judge each generation ───────────────────────────────────────────── */
    size_t n_ok = 0, n_finding = 0, n_stated = 0;
    int obs_blocked = 0;
    for (size_t i = 0; i < g_ngen; i++) {
        gen_t *G = &g_gen[i];
        char tsxpath[4096], lepath[4096];
        snprintf(tsxpath, sizeof tsxpath, "%s/%s-system-generation/etc/fx-claim.tsv",
                 g_store_abs, G->genhash);
        snprintf(lepath,  sizeof lepath,  "%s/%s-system-generation/etc/fx-claim.le",
                 g_store_abs, G->genhash);

        G->tsv = read_file(tsxpath, &G->ntsv, &G->tsv_absent);
        G->le  = read_file(lepath,  &G->nle,  &G->le_absent);
        if (!G->tsv_absent && !G->le_absent) {
            /* the CLAIM's identity: the two rows' bytes, in the row-then-
             * argument order — the convention the record states */
            size_t want = G->ntsv + G->nle;
            unsigned char *all = xmalloc(want);
            memcpy(all, G->tsv, G->ntsv);
            memcpy(all + G->ntsv, G->le, G->nle);
            sha256_hex(all, want, G->claimsha);
            free(all);
        }

        /* THE .operator BINDING (rounds 3-4).  The OUTCOME question — is
         * this generation judged at all? — is answered across ALL landings:
         * a genhash can land at more than one version (the substrate's own
         * adopt-if-exists: a rollback, an operator's retry of the same
         * config), and each landing has its terminal row.  ANY landing
         * whose row is outcome ok makes the generation a judged one; the
         * round-2 seat bound the outcome to the FIRST landing's row alone
         * and the round-2 review measured the escape — a generation that
         * first landed behind a dhake-failed publish and later re-landed
         * ok (the operator's natural retry) answered verdict=skipped
         * FOREVER, and the live, ok-published generation's claim was never
         * judged.  ROUND 4 widened WHICH ROWS the loop reads: the writer's
         * terminal ROLLBACK rows land too — init.zig:4056 appends the ok
         * rollback row when the rollback LANDED, its to-version the
         * CURRENT after the wrap: the RESULT version the SOFT rollback
         * publishes (store.zig:1240 — "two new versions, CURRENT advances
         * monotonically"; its snapshot names the ROLLED-BACK-TO genhash,
         * which is what row_lands binds on — the to-version is NOT the
         * rollback's target operand), so a
         * generation published by `fxctl rollback` lands exactly as an
         * activate lands; the round-3 filter dropped those rows, and a
         * generation whose live landing was a rollback was skipped forever
         * (measured, round-4 review).  `refused-config` rollback rows name
         * the target too (init.zig:4013 — the rollback DID land; the
         * config was refused after); `refused`/`unverified` rollback rows
         * and every `shutdown` row carry to='-' and land nothing
         * (row_lands).  The FROM-VERSION cross-check (BINDING 3) binds the
         * FIRST landing's ACTIVATE row alone — the claim's authoring
         * context (see binding3_opfrom for the measured trap against
         * binding the ok row): a rollback row's from-version is the world
         * the rollback moved FROM, and a rollback returning to the first
         * landing's own version would bind that pre-rollback world — a
         * false-fail.  First-match WITHIN one to-version is exact on real
         * stores for ACTIVATE rows: the writer appends exactly ONE
         * terminal row per activation (init.zig: refused-config /
         * dhake-failed / unverified / ok, each naming the LANDED version)
         * and each publish is a fresh version.  ROLLBACK rows CAN share a
         * to-version on a real journal (two rollbacks returning to one
         * version) — safe: the outcome question is a fold over ALL landing
         * rows (ok_seen is order-independent), and the only first-match
         * consumers here are the activate-bound ones. */
        G->op_state = 0;
        G->opfrom[0] = 0;
        char first_tov[32], land_outcome[64] = "";
        snprintf(first_tov, sizeof first_tov, "%u", G->version);
        int ok_seen = 0, any_seen = 0, first_seen = 0;
        for (size_t r = 0; r < g_nop; r++) {
            /* the LANDING actions: the writer's generation-plane arms that
             * name a landed version.  A FUTURE writer action that lands
             * versions must be added here BY NAME — an unknown action
             * landing nothing is this filter's stated direction (the
             * round-4 blocker was exactly such a drop).  The OUTCOME
             * vocabulary is read by NAME too (the strcmp below): a FUTURE
             * outcome name meaning 'landed fine' — or an outcome-shape
             * change — silently counts not-ok, the exact SIBLING of the
             * future-ACTION residual (stated round 5 beside it). */
            int is_act = !strcmp(g_op[r].action, "activate");
            if (!is_act && strcmp(g_op[r].action, "rollback")) continue;
            if (!row_lands(g_op[r].tov, G)) continue;
            if (!any_seen++)
                snprintf(land_outcome, sizeof land_outcome, "%s", g_op[r].outcome);
            if (!strcmp(g_op[r].outcome, "ok")) ok_seen = 1;
            if (is_act && !first_seen && !strcmp(g_op[r].tov, first_tov)) {
                first_seen = 1;
                snprintf(G->opfrom, sizeof G->opfrom, "%s", g_op[r].fromv);
                snprintf(land_outcome, sizeof land_outcome, "%s", g_op[r].outcome);
            }
        }
        if (ok_seen)
            G->op_state = 1;            /* some landing published ok: judged */
        else if (any_seen) {
            G->op_state = 2;            /* landings, none ok: skipped, stated */
            snprintf(G->opnote, sizeof G->opnote,
                     "operator-outcome-%s-no-disagreement", land_outcome);
        }
        /* else op_state stays 0: no row names ANY landing of this
         * generation — stated, and its TWO DIRECTIONS both meet a reader
         * here: an unjournaled publish (a non-nonce boot, or one of the
         * unjournaled-landings bound's moves) is JUDGED — loud-ish; but a
         * TORN ok landing row BESIDE a kept non-ok row leaves the non-ok
         * row standing alone (any_seen, !ok_seen) -> SILENT FALSE-SKIP
         * forever, the OPPOSITE of this branch's judged direction.  The
         * same host-trust cell (corruption/tamper only; the writer's ONE
         * write under O_APPEND is the control): a FORGED to-version (its
         * snapshot does not name the genhash) or outcome lookalike (any
         * byte different from "ok") silently drops the landing — a
         * false-SKIP, never a false judge. */
        if (g_journal_absent)
            snprintf(G->opnote, sizeof G->opnote, "no-operator-journal-cross-check-skipped");

        printf("generation\t%s\tversion %u\n", G->genhash, G->version);

        /* ── the claim's presence ── */
        if (G->tsv_absent) {
            /* the .le alone is not a claim: the ROW is the claim (the
             * argument rides beside it, never instead of it) */
            obs_t *o = obs_find(G->genhash);
            if (enroll || (o && !strcmp(o->verdict, "claimless")))
                snprintf(G->cls, sizeof G->cls, "claimless"); /* stated / the baseline saw it */
            else {
                snprintf(G->cls, sizeof G->cls, "no-claim");
                add_finding("no-claim", G->genhash,
                            "a generation without a claim POST-enrollment — the §1a gap-3 error "
                            "is reading this absence as 'none occurred'; it keeps firing until "
                            "acted on (--re-enroll)");
            }
        } else if (G->ntsv == 0) {
            /* an EMPTY row file is not claimless silence — it is something
             * wearing the claim's path (extraEtc is a convention, not a
             * schema, plan risk 5): loud, named */
            snprintf(G->cls, sizeof G->cls, "not-a-claim");
            add_finding("not-a-claim", G->genhash,
                        "%s is empty — an empty claim file is not a claimless generation; it is "
                        "the claim's path carrying nothing", tsxpath);
        } else if (G->le_absent) {
            snprintf(G->cls, sizeof G->cls, "not-a-claim");
            add_finding("not-a-claim", G->genhash,
                        "%s exists but its argument %s does not — a claim row without its "
                        "free-LE argument is not a claim", tsxpath, lepath);
        } else {
            /* ── the seat's binding, then the evaluator ── */
            char rowbuf[LINE_MAX_];
            size_t want = G->ntsv < LINE_MAX_ - 1 ? G->ntsv : LINE_MAX_ - 1;
            memcpy(rowbuf, G->tsv, want);
            rowbuf[want] = 0;
            char *first_line = strtok(rowbuf, "\n");
            char *f[8];
            size_t nf = first_line ? split_fields(first_line, f, 8, "\t\r\n") : 0;
            int row_ok = (nf == 4);
            long from_resolved = -1;
            int stale = 0;
            char stalewhy[1024] = "";
            if (G->op_state == 2) {
                /* the OUTCOME gates the judgment: a publish whose landing
                 * rows name NO ok outcome is SKIPPED — stated, never judged
                 * (the documented class; the note above names the outcome;
                 * plan risk 6: `dhake-failed`/`refused-config` LANDED their
                 * version (init.zig:3866/:3952/:4013), `refused`/
                 * `unverified`/`failed:<rc>` name none — there is no
                 * judgment to run either way) */
                snprintf(G->cls, sizeof G->cls, "skipped");
            } else {
                if (row_ok) {
                    from_resolved = resolve_from_version(f[2]);
                    if (from_resolved < 0) {
                        stale = 1;
                        snprintf(stalewhy, sizeof stalewhy,
                                 "the claim's from_version '%s' names no published generation — the "
                                 "claim's world model does not exist in this store", f[2]);
                    }
                } else {
                    /* the ROW is the evaluator's to refuse BY NAME (the boundary
                     * is its judgment predicate; the seat owns the record).  The
                     * seat's bindings cannot run — stated — and the evaluator's
                     * refusal (malformed-claim) is what the record carries: it
                     * refuses the row BEFORE it reads any fact, so the dumps
                     * below name the riding version only so they name a real
                     * version; they cannot affect this verdict. */
                    snprintf(G->opnote, sizeof G->opnote, "row-unparsable-seat-bindings-skipped");
                }
                binding3_opfrom(G, row_ok ? f[2] : NULL, &stale, stalewhy, sizeof stalewhy);
            }

            if (stale) {
                snprintf(G->cls, sizeof G->cls, "stale-world");
                add_finding("stale-world", G->genhash, "%s", stalewhy);
            } else if (G->op_state != 2) {
                /* the VERDICT: ONE subprocess, reading THE GENERATION'S OWN
                 * BYTES (the record's subject, never a copy) */
                char dumpdir[4200];
                const char *tmp = getenv("TMPDIR");
                snprintf(dumpdir, sizeof dumpdir, "%s/fx-claim-dumps.XXXXXX",
                         tmp && *tmp ? tmp : "/tmp");
                if (!mkdtemp(dumpdir)) die("cannot create the dumps dir: %s", strerror(errno));
                /* BINDING 2: for a parsable row the dumps are --as-of the
                 * version the ROW's from_version resolves to (the world the
                 * claim claims to come from), never --as-of the riding
                 * version */
                write_facts_dumps(row_ok ? (unsigned)from_resolved : G->version, dumpdir);
                int rc = run_evaluator(G, tsxpath, lepath, dumpdir, &G->evalout);
                G->evaled = 1;
                char p1[4400], p2[4400], p3[4400];
                snprintf(p1, sizeof p1, "%s/generation_config.dump", dumpdir);
                snprintf(p2, sizeof p2, "%s/install.dump", dumpdir);
                snprintf(p3, sizeof p3, "%s/provides.dump", dumpdir);
                unlink(p1); unlink(p2); unlink(p3);
                rmdir(dumpdir);
                verdict_class(G->evalout, rc, G->cls, sizeof G->cls);
            }
        }

        /* ── the obs comparison (the durable record is compared on every run
         *    after the baseline) ── */
        if (!enroll) {
            obs_t *o = obs_find(G->genhash);
            if (o) {
                if (strcmp(o->verdict, G->cls)) {
                    add_finding("verdict-rewritten", G->genhash,
                                "the observation records verdict '%s' (version %u) and this run "
                                "recomputed '%s' — a REWRITTEN VERDICT; the observation is not "
                                "rewritten until --re-enroll", o->verdict, o->version, G->cls);
                    snprintf(G->cls, sizeof G->cls, "verdict-rewritten");
                }
                /* a baseline recorded as claimless ("-") that now carries
                 * bytes differs too: the claim appeared under a genhash the
                 * baseline saw claimless — the same rewrite, named */
                if (!G->tsv_absent && strcmp(o->sha, G->claimsha)) {
                    add_finding("claim-rewritten", G->genhash,
                                "the claim bytes (sha256 %.12s..%.6s) are not what the observation "
                                "recorded (%.12s..%.6s) — a PUBLISHED generation's claim was "
                                "rewritten in place",
                                G->claimsha, G->claimsha + 58, o->sha, o->sha + 58);
                    snprintf(G->cls, sizeof G->cls, "claim-rewritten");
                }
            }
        }

        if (G->evaled && G->evalout) {
            char *save = NULL;
            char *dupbuf = xstrdup(G->evalout);
            for (char *tok = strtok_r(dupbuf, "\n", &save); tok; tok = strtok_r(NULL, "\n", &save))
                printf("eval\t%s\n", tok);
            free(dupbuf);
        }
        /* the refusal classes the EVALUATOR produced (malformed-claim,
         * head-forgery, premise-false, justified-not-derived, ...) are
         * findings by being verdicts: one generic finding names the class
         * (the reason is in the eval block above).  The classes whose own
         * checks already reported (stale-world, not-a-claim, no-claim,
         * verdict-rewritten, claim-rewritten) are not re-reported here, and
         * ok / claimless / skipped are stated, not findings. */
        if (strcmp(G->cls, "ok") && strcmp(G->cls, "claimless") && strcmp(G->cls, "skipped")
            && strcmp(G->cls, "stale-world") && strcmp(G->cls, "not-a-claim")
            && strcmp(G->cls, "no-claim") && strcmp(G->cls, "verdict-rewritten")
            && strcmp(G->cls, "claim-rewritten"))
            add_finding(G->cls, G->genhash,
                        "the evaluator refused this claim by name (its reason is in the "
                        "eval block above)");
        printf("record\t%s\tversion=%u\tverdict=%s\tclaim-sha=%s\top-from=%s%s%s\n",
               G->genhash, G->version, G->cls,
               G->tsv_absent ? "-" : G->claimsha,
               (G->op_state == 1 && G->opfrom[0]) ? G->opfrom : "-",
               G->opnote[0] ? "\tnote=" : "", G->opnote);
        if (!strcmp(G->cls, "ok")) n_ok++;
        else if (!strcmp(G->cls, "claimless") || !strcmp(G->cls, "skipped")) n_stated++;
        else n_finding++;
        if (cls_blocks_obs(G->cls)) obs_blocked = 1;
    }

    /* ── the findings block (column 0, so gates can grep it) ─────────────── */
    for (size_t i = 0; i < g_nfindings; i++)
        printf("finding\t%s\t%s\t%s\n",
               g_findings[i].cls, g_findings[i].gen, g_findings[i].detail);

    int coherent = (g_nfindings == 0);
    printf("# fx-claim: %zu generation(s): %zu ok, %zu refused/finding, %zu stated-not-judged; "
           "%zu finding(s)\n", g_ngen, n_ok, n_finding, n_stated, g_nfindings);
    if (enroll)
        printf("fx-claim: ENROLLMENT: first-ever observation — %zu generation(s) recorded, "
               "compared against nothing (stated, never silent)%s\n", g_ngen,
               coherent ? "" : " — the verdicts above are the judgment, not a comparison");
    if (!obs_blocked) {
        obs_write();
        printf("fx-claim: observation written\n");
    } else {
        /* a disagreement with the previous observation is resolved by acting,
         * not by rewriting the baseline under itself */
        printf("fx-claim: observation NOT rewritten (verdict-rewritten / claim-rewritten / "
               "no-claim keep reporting until acted on or --re-enroll)\n");
    }
    printf("verdict\t%s\n", coherent ? "coherent" : "disagreed");
    return coherent ? 0 : 1;
}
