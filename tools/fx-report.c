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
 *                                     (bootlog_append's "%u %s %u %s").
 *                                     THE NONCE BINDS A KERNEL BOOT, not a
 *                                     PID1 lifetime: fx-init's SOFT REBOOT
 *                                     re-enters the boot path under the SAME
 *                                     fx.bootnonce= (the kernel did not
 *                                     restart), so ONE nonce can carry MORE
 *                                     THAN ONE boot's in-progress/verdict
 *                                     lines, delimited by an ADMITTED
 *                                     .operator `reboot` row carrying the
 *                                     same nonce (the anchor fx-audit's
 *                                     accounting rests on; see that seat's
 *                                     bound, not restated here)
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
 *                                     arms, init.zig:3692/:3801/:3841/:3866/
 *                                     :3952/:3965/:3985/:3994/:4013/:4056).
 *                                     RE-AIMED at the S3 re-measure: this
 *                                     list was 21 lines short of the arms it
 *                                     names — the DISK_DEVS insertion was
 *                                     applied to the FIRST ref of the group
 *                                     only, so six continuation members kept
 *                                     the pre-insertion number through two
 *                                     later passes, naming two RE-ARM
 *                                     comments, a reply fprintf and three more
 *                                     comments.  The taxonomy's
 *                                     `operator-intervention` row below, which
 *                                     always named the ten appends correctly,
 *                                     is the in-file control that decided
 *                                     which of the two lists was stale.
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
 * "failed", init.zig:3803; "dhake-failed", :3954), rollbacks and
 * shutdowns (rt_control, the shared activate|rollback ctrl arm, :3715) —
 * lives at /run/fx/log.db (DEFAULT_RUN "/run/fx", init.zig:33; path
 * built :4663, opened :4664).  Post-pivot "/" is TMPFS (init.zig's M4
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
 * Host tool (like the audit: native, no musl variant).  Links the
 * vendored sha256 and yyjson (the host log and the guest transcript are
 * JSON).  Usage:
 *   fx-report [--store DIR] [--fxstore BIN] [--max-config-lines N]
 *             [--proxy-log FILE] [--transcript FILE]
 * Exit: 0 documented (no findings), 1 findings present, 2 tool error.
 *
 * THE CALL CLASS (P9, with --proxy-log and/or --transcript): the host
 * proxy's ONE LOG (tools/fx-hostgate.c) joined, by call_id, to the guest's
 * TRANSCRIPT (messages.jsonl).  The host gate delivers a denial by
 * REWRITING the call's name to a reserved name and substituting a denial
 * text; the guest records the REWRITTEN name and a generic sentinel and
 * NEVER learns the true verb — so this join is the only place a denial's
 * true name, verdict, author and reason are queryable together.  The seat
 * surfaces the TRIPLE (call-record / call-verdict / call-outcome), the
 * DISAGREEMENT (call-disagreement), the join's absences in BOTH directions
 * (call-join, each its own row and meaning), and the log's echo telemetry
 * (call-telemetry; NO LANE STOP by default — the deliberate G7 demotion).
 * It READS both sides and never rewrites either.
 *
 * THE EXEC DIMENSION (S4), on the SAME class: every judged call also gets a
 * `call-exec` row saying WHICH SIDE RAN IT — MEASURED from the row's own
 * `exec` field when the HOST executed the call, and DERIVED from the
 * writer's stated grammar when it is absent (absence means the guest ran
 * it).  §7.1a's residual is why: an egress grant is a CAPABILITY INCREASE,
 * and a report that could not tell a host-executed call from a guest one
 * would be blind to exactly that.
 *
 * THE REACH CLASS (S4): the WEAKENED declared-vs-observed audit, its own
 * rows and its own two findings — stale-class-row (a pinned class row no
 * observed call exercised: a STALE GRANT) and pin-drift (an artifact that is
 * not the bytes PINS froze).  It is NOT the type-enforced audit round 1
 * would have given, because an egress call is judged ARGUMENTS rather than
 * typed: "declared" here is the operator's pinned class tables plus PINS, and
 * the strong "observed traffic no declaration licenses" direction does not
 * exist in this shape.  It says so in the taxonomy, in both finding rows and
 * in its bound (bound/reach-audit-is-the-weakened-one), and it keeps the
 * §1a gap-3 discipline on every side: a missing log, policy dir, PINS file
 * or --class-arg mapping is NOT-KNOWN, never "none" and never "stale".
 *
 * THE SANDBOX CLASS (S4, palisade): the same §7.1a question, one layer
 * deeper — since S3 the sandbox wraps EVERY host spawn, so the composed spec
 * per tool (the executor's baseline + the tool's sidecar, read from the
 * proxy's OWN --print-sandbox) is itself a CAPABILITY DECLARATION.  The class
 * carries the row's `sandbox` field as a COLUMN of the existing call rows,
 * then compares the DECLARED composition against the specs the log RECORDED
 * each host call applying, and pins the one pinned half (ops-sandbox.tsv).
 * A widening is a finding (nothing pins the baseline or the sidecar, so no
 * release can license one); the mirror direction is NAMED and not judged,
 * because an operator tightening row produces exactly that shape.  It is the
 * WEAKENED audit (two specs compared as text), stated in the taxonomy, the
 * bounds and the rows — and a sandbox change being VISIBLE is not the same
 * as the sandbox being STRONG.
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

#include "dhall.h"  /* sha256_hex (vendored dhall-c/sha256.c) */
#include "yyjson.h" /* the host log and the guest transcript are JSON */

/* ── knobs (every cap is LOUD on overflow: silently reporting a truncated
 *    view is exactly the silent pass this family refuses) ─────────────── */

#define MAX_VERSIONS 512
#define MAX_IDENTS MAX_VERSIONS /* distinct content identities <= versions */
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

/* ── THE CALL CLASS (P9): the host proxy's ONE LOG joined, by call_id, to
 *    the guest's TRANSCRIPT.  The host gate (tools/fx-hostgate.c) delivers
 *    a denial by REWRITING the call's name to a reserved name and
 *    substituting a denial text; the guest's transcript records the
 *    REWRITTEN name + a generic sentinel and NEVER learns the true verb.
 *    So the only place a denial's TRUE NAME, its VERDICT, its AUTHOR and
 *    its REASON exist together is the host's log, and nothing joins that
 *    log back to what the guest recorded until THIS class.  Every field
 *    below is the log's own, carried VERBATIM: the seat surfaces the
 *    triple (CLAIM/VERDICT/OUTCOME), the DISAGREEMENT, and the join's
 *    absences, and derives nothing about the judgement. */

/* One CALL row of the host log — the triple the seat is asked to make
 * queryable.  verdict/author/allow_scope/refusal_name/reason are NULL when
 * the row carries no verdict field (no policy ran: the P2 shape), and the
 * seat must then render NO fabricated verdict (`NOT-RECORDED`, never
 * "allowed"). */
typedef struct {
    char *call_id;        /* the join key — NEVER rewritten on either leg */
    long turn;
    int turn_set;
    char *true_name;
    char *args;           /* the model's args text, VERBATIM (the classed
                           * argument is read out of it for the reach class;
                           * never re-rendered) */
    char *justification;  /* the CLAIM, from the call's args */
    char *exec;           /* S4: WHICH SIDE RAN IT — the row's own `exec`
                           * field, present ONLY on a host-executed call */
    char *sandbox;        /* S4 (palisade): the row's own `sandbox` field —
                           * the spec the spawn APPLIED, present only on a
                           * host-executed row and carried VERBATIM */
    int pending;
    char *outcome;        /* the OUTCOME: the replayed function_call_output */
    char *verdict;
    char *author;
    char *allow_scope;    /* the allowed row's own reading — VERBATIM */
    char *refusal_name;
    char *reason;
    unsigned lineno;
} hostcall_t;

/* One telemetry row of the host log (types unjoined-output / echo-anomaly /
 * unresolved-substitution): a RECORD of a join that could not be made — NOT
 * a trigger (the deliberate G7 demotion). */
typedef struct {
    char *type;
    char *call_id;
    char *text;           /* `output`, or `true_name` for the subst anomaly */
    long turn;
    int turn_set;
    unsigned lineno;
} calltele_t;

/* One call the GUEST recorded in its transcript (messages.jsonl): the
 * assistant tool_call (the id + the REWRITTEN name + the args) and the
 * role=tool result (the sentinel output), keyed by call_id. */
typedef struct {
    char *call_id;
    char *name;      /* NULL when only a tool result was recorded */
    int has_output;
    char *output;
    unsigned lineno;
} guestcall_t;

#define MAX_CALL_ROWS 65536
#define MAX_TELE_ROWS 4096
#define MAX_GUEST_ROWS 65536
#define MAX_LOG_LINE (1u << 20) /* a row longer than this is refused LOUD */

static hostcall_t g_hcalls[MAX_CALL_ROWS];
static unsigned g_nhcalls;
static calltele_t g_tele[MAX_TELE_ROWS];
static unsigned g_ntele;
static guestcall_t g_guest[MAX_GUEST_ROWS];
static unsigned g_nguest;

static const char *g_proxy_log;  /* --proxy-log: the host proxy's one log */
static const char *g_transcript; /* --transcript: the guest's messages.jsonl */
static int g_plog_present, g_tran_present; /* the named file existed */

/* ── S4: THE REACH CLASS — the WEAKENED declared-vs-observed audit ────────
 * "declared reach" is what the operator PINNED and what the host can run:
 * the class tables in --policy-dir (policy/ops/ops-aliases.tsv — the PATH
 * dimension — and policy/ops/ops-hosts.tsv — the AUTHORITY dimension), each
 * row a GRANT (a class, and whether it is protected), and the PINS file
 * that freezes them.  "observed" is the one log's own call rows.  The two
 * findings that SURVIVE in this shape, each its own row with its own
 * meaning: stale-class-row (a pinned row no observed call exercised — a
 * STALE GRANT) and pin-drift (an artifact that no longer hashes to PINS).
 *
 * THE WEAKENING IS STATED, NOT SOFTENED: this is NOT the type-enforced
 * audit round 1 would have given.  Egress is JUDGED ARGUMENTS, not a type,
 * so there is no per-generation declaration for observed traffic to
 * violate, and the "unlicensed traffic" direction does not exist here.  What
 * is left is what the pinned tables + the log can honestly support.
 *
 * TWO DIRECTIONS OF ABSENCE, once per side (§1a gap 3), and NOTHING here
 * ever reads a missing side as "none": no --policy-dir means the DECLARED
 * side is NOT-KNOWN (never "nothing is granted"); no --proxy-log means the
 * OBSERVED side is NOT-KNOWN (never "nothing was called", and emphatically
 * never "every row is stale"); no --class-arg for a tool means that tool's
 * classed argument cannot be attributed, so the rows only it could have
 * exercised read NOT-KNOWN, not stale. */
#define MAX_CLASSARGS 32
#define MAX_REACH_ROWS 4096
#define MAX_PIN_ROWS 64

typedef struct {
    char *dim;    /* the DIMENSION the classed argument belongs to:
                   * "path" (the ops-aliases table) or "authority" (the
                   * ops-hosts table) — the caller states it because the
                   * registry is C and this seat will not respell it */
    char *tool;   /* the call's true_name / the guest verb's name */
    char *key;    /* the argument key the registry declares as classed */
} classarg_t;

typedef struct {
    char *table;    /* the artifact the row came from (its file name) */
    char *pattern;  /* the row's pattern, VERBATIM */
    char *cls;      /* the class the seat injects */
    int  prot;      /* protected: yes=1, no=0 */
    unsigned lineno;
} reachrow_t;

typedef struct {
    char name[256];  /* the artifact name PINS names */
    char want[65];   /* PINS' sha256 */
    char got[65];    /* the bytes on disk now ("" when the file is absent) */
    int  present;
} pinrow_t;

static const char *g_policy_dir;             /* --policy-dir (the DECLARED side) */
static classarg_t g_classargs[MAX_CLASSARGS];
static unsigned g_nclassargs;
static reachrow_t g_rrows[MAX_REACH_ROWS];
static unsigned g_nrrows;
static pinrow_t g_pins[MAX_PIN_ROWS];
static unsigned g_npins;
static int g_pins_present, g_alias_present, g_hosts_present;
static int g_reach_tables_read;  /* at least one class table was read */

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
 * (init.zig:3801/:3866; refused-config is written by the rollback arm
 * too, :4013 — the writer calls it the same record from the other
 * direction), and refused-config means the generation DID land in the
 * store but PID1 REFUSED it: the declared service set is past its bound
 * OR the configuration could not be read at all (read_store_facts rc != 0,
 * the activate arm's two message forms at :3872/:3878 and the rollback
 * arm's at :4021/:4028).  `refused` is the rollback arm's when the STORE
 * rejected the target (:3994).  NOT refusals, and named as such in the
 * taxonomy:
 * `dhake-failed` (the generation DID land; the live-root reapply failed,
 * :3952) and `unverified` (the store could not be re-opened to confirm —
 * the record is AMBIGUOUS, which is not the same as refused), and `ok`.
 * FOUR of the refs above were RE-AIMED at the S3 re-measure: `:3856` named
 * the rollback REFUSED branch's rationale comment rather than the
 * refused-config append (:4013), and the four "message forms" refs named
 * four COMMENT lines rather than the four snfmtRaw calls (:3872/:3878 and
 * :4021/:4028). */
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
      "<store>/.bootlog line <v> ok|failed <epoch> <nonce> (fx-init bootlog_append).  THE NONCE IS THE KERNEL BOOT'S, not a PID1 lifetime's: a SOFT REBOOT re-enters the boot path under the SAME nonce (apply_kernel_nonce re-latches it — no kernel restarted), so ONE nonce may carry a SECOND in-progress/verdict pair for the same version, and the .operator `reboot` row that admits it (same nonce, from-version = the generation being re-judged) is the record that says so.  Two lines are therefore NOT by themselves evidence of a forged pair — the row is what separates a reboot from a forgery, and fx-audit is the seat that adjudicates it",
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
      "MEASURED — <store>/.operator rows: one line per intervention on the generation plane, written by PID1's control handler (fx-init ca9cb06) or, since the runtime-record closure, by fx-activate ITSELF for a publish it committed OUTSIDE that handler on a boot carrying an fx.bootnonce= (the file's own OPERATOR_HEADER, operator_journal.zig:122, IS the definition — ONE definition, imported by both writers): <epoch> <action> <arg> <outcome> <from-version|-> <to-version|-> <boot-nonce|none>, appended + fsync'd BEFORE the reply is flushed (operator_append: shutdown :3692, activate-failed :3801, unverified :3841, refused-config :3866, dhake-failed :3952, ok :3965, rollback unverified :3985, refused :3994, refused-config :4013, ok :4056).  SECOND WRITER (the runtime-record closure): fx-activate records the publish IT committed OUTSIDE that handler — one row, activate/ok or activate/unverified, on a boot carrying an fx.bootnonce= — through the SAME grammar and header (selfRecord, fx-init activate.zig:898/:1769/:1755; the writer itself, operator_journal.zig:235).  action = the ctrl arm that wrote it, arg = the operator's operand VERBATIM, outcome = ok | failed:<rc> | refused | refused-config | dhake-failed | unverified.  The journal records the GENERATION PLANE ONLY — its header names what it does NOT record (the reads, file transfers, the shell, per-service commands, probe) and what it cannot record AND cannot DETECT: the paths that bypass PID1's handler (host-side `fxstore rollback`, `rollback --hard`, a hand-edited CURRENT).  DERIVED — the RETAINED FALLBACK, for a store with NO .operator and for exactly those bypass paths: two signatures. (restore) version r whose genhash matches a version TWO-OR-MORE back (a duplicate of only the IMMEDIATELY-PRECEDING generation is fx-activate's own publish-of-live — MEASURED: every activation after the first leaves that benign pair — or gc's publish-first, and is NOT this class) and no .recovery row publishes r — the ctrl rollback arm (init.zig:3989) and host `fxstore rollback` drive the SAME soft rollback and append NOTHING to .recovery; (current-repoint) CURRENT != newest. Both are DERIVED, never a verdict.  `reboot` IS ONE OF THE ACTIONS (fx-init's soft reboot): it moves NO generation (the to-version field is '-') and its arg is the requester's reason token, and its outcome is the SIX-TOKEN admission vocabulary ok | not-decided | boot-failed | shell-open | same-version-loop | exec-error — NOT the activation vocabulary, deliberately: none of those tokens matches this seat's activation-refusal predicate (failed:<rc> / refused / refused-config), so a REFUSED REBOOT is never emitted as an activation refusal while it IS emitted here as an operator intervention.  The row records the ADMISSION, not the execution: an admitted reboot whose execve failed is `exec-error`, and one that was admitted and never ran is visible only as the ABSENCE of a later .bootlog line under that nonce.",
      "TWO DIFFERENT STATES, never conflated: (i) .operator PRESENT with zero rows = no generation-plane intervention in the retained journal — a MEASUREMENT, not a gap; (ii) .operator ABSENT = a store PREDATING ca9cb06 (or one never booted under it) — NOT 'none occurred' (see absence/.operator).  For (ii), and for the bypass paths the journal's own header lists as NOT-RECORDED-AND-NOT-DETECTABLE, the DERIVED signature is the fallback and it is a DISJUNCTION: an operator rollback OR a deliberate re-activation of an older config — either way content moved back without the automatic .recovery row — OR a removed .recovery row, which the AUDIT seat's previous-observation comparison, not this seat, is built to catch.  The derived signature is only a backward move or a stale CURRENT, and gc/renumber can destroy both.  A journal row does NOT suppress the derived row: it can EXPLAIN a backward move but cannot prove the journal saw every path that produced one." },
    /* S3 re-measure: this row cited "DEFAULT_RUN :32", which is
     * DEFAULT_STORE (DEFAULT_RUN is :33 — the retention table and the
     * header say so twice).  The row is PRINTED, so the fix is a
     * behaviour-visible byte change of a citation, nothing else. */
    { "activation-refusal",
      "MEASURED — <store>/.operator rows whose outcome is a refusal (fx-init ca9cb06): failed:<rc> (the activate executor exited rc; nothing landed — init.zig:3801), refused-config (the generation DID land in the store but PID1 REFUSED it — the declared service set past its bound, or a configuration read_store_facts could not read: :3866 from the activate arm, :4013 from the rollback arm, the writer's own 'same durable record from the other direction'), refused (the STORE rejected a rollback target — :3994).  Recorded in the SAME journal and NOT this class: dhake-failed (:3952 — the generation DID land, the live-root reapply failed) and unverified (:3841 — the store could not be re-opened to confirm, i.e. AMBIGUOUS, which is not the same as refused).  The tmpfs runtime log that held these (rt_effect activate failed|dhake-failed, init.zig:3803/:3954, DEFAULT_RUN :33) still dies at every reboot and is NOT read by this seat.",
      "no-row-with-a-refusal-outcome-in-the-retained-journal = no RECORDED refusal within the journal (a count of RECORDED refusals, never of attempts).  This absence-meaning WAS 'NOT-DURABLY-RECORDED' before ca9cb06 — a refused activation left NOTHING in the store (fx-activate refuses before touching it) and PID1's record of it lived in /run's tmpfs — and it is that again EXACTLY WHEN .operator IS ABSENT: a store predating the journal CANNOT answer this class, and the report says so via absence/.operator instead of printing a zero.  Bounds carried INTO the class: a REFUSAL row is written by PID1's control handler alone (a direct exec records only a publish that reached commit), so an fx-activate that refuses outside that handler is invisible; `unverified` rows are ambiguity, not refusals; and root in-guest can forge or truncate the file exactly as it can .bootlog — a row is CHECKABLE against the store's version/genhash history, not authoritative over it." },
    { "claim",
      "MEASURED — <store>.fx-claim-obs rows (the JUDGE SEAT's observation — fx-claim's format-1 record of the TRIPLE per generation: the claim that rode into the activation as the two extraEtc rows /etc/fx-claim.tsv + /etc/fx-claim.le, the VERDICT the frozen policy's evaluator reached, and the OUTCOME cross-check against the .operator row, content-joined): claim <genhash> version <N> verdict <cls> claim-sha <sha|-> op-from <v|-> (the observation's format header IS the definition — ONE writer).  The claim BYTES live in the retained generation dir (the claim-rows retention row); this seat reads the VERDICT record and recomputes nothing (bound/claim-check-is-a-lever)",
      "TWO DIRECTIONS, the §1a gap-3 discipline: (i) the observation PRESENT and a row's verdict claimless = NONE-OCCURRED for that generation — MEASURED by a judge that RAN, within the enrollment boundary the observation's existence sets; a LIVE generation the observation does NOT name is NOT 'none occurred' — the report emits claim-record ... NOT-RECORDED for it (the judge has not run since the publish, or its run disagreed — no-claim — and the observation kept its baseline); (ii) the observation ABSENT = NOT-DURABLY-RECORDED — no judge has ever run on this store (or the observation was removed): the report cannot say whether any claim rode in or any verdict was reached, and says so (absence/.fx-claim-obs) instead of printing a zero.  verdict-rewritten / claim-rewritten NEVER persist in the observation (the seat refuses to rewrite under them) — their audit is the judge's own next run, not this seat's" },
    { "content-recurrence",
      "DERIVED: .recovery data rows whose trailing genhash is IDENTICAL (the .recovery header's own semantics: the same content re-failing).  THIS IS THE NARROWER CLASS and the difference is decisive: it reads ONE file, so it sees only the content an AUTOMATIC roll-forward RESTORED, and it CANNOT see a repeat that a RE-ACTIVATION produced (the agent, a shell or an operator re-issuing the same configuration) — which is the OSCILLATOR's actual driver.  The `progress` class below keys on the CHAIN's own genhash and sees both; the two are not spellings of one class, and a reader who takes this row for that question is the silent defect the distinction exists to prevent",
      "no-repeated-genhash=no-recurrence-WITHIN-.recovery's-surviving-rows — and never 'no recurrence': a store whose repeats were all re-activations has no such row at all, so that question must be read from the `progress` class" },
    { "progress",
      "MEASURED — the CHAIN's own content identities: `fxstore timeline` (every published version) + `fxstore facts generation --as-of <v>` (the genhash — the SAME key fx-init's guard_stats_for uses) + <store>/.bootlog (the per-version verdict).  ONE progress-content row per DISTINCT genhash in first-published order: versions (the publisher) / runs (the system: MAXIMAL consecutive runs, which collapses the publish protocol's own pair) / failed / in-progress / ok / not-judged / other, its first and last version, whether it is the LIVE one, and its CLASSIFICATION (new | repeat-of-<vN> | benign-publish-pair | not-known).  ACTIVITY is those versions minus the publish pair and minus NOT-KNOWN; PROGRESS is the FIRST SIGHTING of an identity.  A repeat is zero progress BY DEFINITION (same content, new number)",
      "TWO DIRECTIONS, and they are the load-bearing part: (i) NO `generation` facts as of a version = that version's content identity is NOT-KNOWN — its OWN count, in NEITHER activity nor progress, and never 'the same content as its neighbour' and never 'new content'; (ii) NO .bootlog, or one with no line, = EVERY verdict NOT-KNOWN, so `failed` reads 0 because NOTHING WAS JUDGED and not because nothing failed — the summary prints `verdicts NOT-KNOWN` with the not-judged count, and an absent log must NEVER become a zero; a status word outside the writer's set counts as neither ok nor failed (never as a pass).  NO .recovery changes NOTHING here (this class does not read it — that IS the difference from content-recurrence above).  A store predating .operator leaves the ATTRIBUTION of a repeat NOT-KNOWN, never 'unattributed'" },
    { "call",
      "MEASURED — the host proxy's ONE LOG (tools/fx-hostgate.c --log, one JSONL row per decoded tool call) joined, by call_id, to the guest's TRANSCRIPT (messages.jsonl).  A call row carries the TRIPLE: the CLAIM (the model's true_name and the args, the justification among them), the VERDICT (an allowed row's author + allow_scope; a denied row's author + refusal_name + reason) and the OUTCOME (the replayed function_call_output), plus terminal turn-stats/proxy-exit rows.  The guest records only what CROSSED the gate (the REWRITTEN name fx_host_denied + a generic sentinel), so this join is the ONLY place a denial's true name, verdict, author and reason are queryable together.  The seat READS the log — byte-identical in, byte-identical out; it never re-renders or rewrites it.",
      "TWO DIRECTIONS, the §1a gap-3 discipline, once per side: (i) BOTH records given and a call_id present in one and ABSENT from the other IS a MEASUREMENT — emitted as call-join ... FINDING (host-log-only: the host judged a call the transcript does not record; transcript-only: the guest recorded a call the host never judged) with its meaning stated, so a join that cannot fire FAILS OPEN IN THE RECORD (the P2 lesson); (ii) a side NOT GIVEN (no --proxy-log / no --transcript) is NOT-KNOWN — an absence row is emitted and its silence is NEVER read as 'no call'" },
    { "call-telemetry",
      "MEASURED — the ONE LOG's telemetry rows (types unjoined-output, echo-anomaly, unresolved-substitution), surfaced verbatim as call-telemetry records with their meanings stated",
      "no-telemetry-row-in-the-log = no SUCH anomaly was recorded within the log this run holds — a MEASUREMENT of the log, never a claim that none occurred (the log may be a slice, and a row absent because no proxy ran is not 'no anomaly')" },
    { "call-exec",
      "MEASURED (host) / DERIVED (guest) — the call row's own `exec` field, the ONE value the proxy writes when the HOST ran the call (a declared program from the pinned registry, its bounded result substituted over the guest's sentinel).  Emitted for EVERY judged call, so the §7.1a question 'did this call widen what the agent can reach?' is answerable from the report: a host-executed call IS a capability the guest did not have",
      "no-`exec`-field = the GUEST executed the call, DERIVED from the writer's OWN grammar (the field renders only where the host ran it), never from a default — and unambiguous only because host execution did not exist before the field did.  A call the log does NOT hold is absent from this class entirely: absence here is 'not in this log', never 'not executed'" },
    { "reach",
      "MEASURED/DERIVED — the WEAKENED declared-vs-observed audit, and it is named as weakened on every run (bound/reach-audit-is-the-weakened-one): DECLARED = the operator's pinned class tables (--policy-dir: ops-aliases.tsv's path classes, ops-hosts.tsv's authority classes, each row a GRANT with its protected flag) plus PINS that freezes them; OBSERVED = the one log's own call rows, attributed by the classed argument the CALLER declares (--class-arg DIM:TOOL=KEY).  Rows: reach-pin (each pinned artifact, sha on disk vs the pinned sha), reach-row (each class row and whether an observed call exercised it), reach-class-arg (the declared mappings the attribution rested on)",
      "TWO DIRECTIONS, once per side, and no absence is ever read as 'none': no --policy-dir = the DECLARED side is NOT-KNOWN (never 'nothing is granted'); no --proxy-log, or a log that does not exist, = the OBSERVED side is NOT-KNOWN (never 'nothing was called' — and NEVER 'every row is stale'); no PINS = the pin-drift direction is NOT-KNOWN (never 'no drift'); no --class-arg for a dimension = that dimension cannot be attributed, so its rows read NOT-KNOWN (never stale).  The two FINDINGS are stale-class-row (a pinned grant no observed call consumed — a REVOCATION question) and pin-drift (the artifact on disk is not the artifact PINS froze, reported with BOTH pins)" },
    { "sandbox",
      "MEASURED/DERIVED — the SANDBOX the executor applied, and it is a second WEAKENED audit (bound/sandbox-audit-is-the-weakened-one).  Since S3 (palisade) EVERY host spawn is wrapped: the executor owns a BASELINE (stdio rpath exec prot_exec + loader:rx + libc:r), a tool may declare MORE via a sidecar beside its binary, and the operator's ops-sandbox.tsv row may only TIGHTEN.  DECLARED NOW = the proxy's OWN composition (--proxy BIN --print-sandbox: name<TAB>promises<TAB>static-landlock per tool); RECORDED THEN = the log's per-call `sandbox` field (the spec the spawn APPLIED, carried verbatim and also surfaced as a COLUMN of every call-exec row); PINNED = policy/ops/PINS over ops-sandbox.tsv ONLY.  Rows: sandbox-composed (the declaration, per tool), sandbox-recorded (the applied spec, per tool, with the call count), sandbox-pin (the one pinned half) and sandbox-delta (the difference, direction NAMED).  A widening is its own FINDING, sandbox-widened-since-record: the operator table can only TIGHTEN the applied spec and does not touch --print-sandbox, so an ADDITION comes from the executor baseline or a tool's SIDECAR — and neither is pinned, so no release can license it.  The mirror direction is NAMED and is NOT a finding (an operator tightening row produces exactly that shape)",
      "TWO DIRECTIONS, once per side, and no absence is ever read as 'unchanged': no --proxy = the DECLARED composition is NOT-KNOWN (never 'the sandbox did not change'); no --proxy-log, or a log that does not exist, = the RECORDED specs are NOT-KNOWN (never 'nothing ran widened'); no --policy-dir, no PINS, or a PINS that does not name ops-sandbox.tsv = the PIN direction is NOT-KNOWN (never 'the table is the released one'); a host row with NO `sandbox` field = that call's applied spec is NOT-KNOWN (never 'unsandboxed', never 'the baseline').  WEAKENED, stated: two specs compared as text, never type-enforced — and VISIBLE is not STRONG (promises are coarse, `inet` is any destination; the confinement is per-process, not per-call; there is no uid drop)" },
    { "reboot",
      "MEASURED — <store>/.operator rows whose action is `reboot` (fx-init bb0642f's ctrl arm; ONE row per REQUEST, INCLUDING the refused ones, written before the reply is flushed): <epoch> reboot <reason> <outcome> <from-version> - <nonce>.  The outcome is the WRITER's admission token — one of SIX, and they are THREE different meanings: ok (ADMITTED), exec-error (ADMITTED but the re-entry could not be executed — the machine is UNCHANGED), and four REFUSALS (not-decided, boot-failed, shell-open, same-version-loop).  Rows: reboot-row (one per journal row, with its class), reboot-version (one per from-version, with the verbatim token counts).  A reboot moves NO generation, so the row carries to-version `-` and the STORE cannot show it: this class and the .bootlog's own lines are the whole record",
      "TWO DIRECTIONS, and neither is ever read as the other: (i) .operator PRESENT with NO reboot row = ZERO reboots RECORDED — a MEASUREMENT of the journal (and an fx-init without the verb cannot write a row at all, so it is not evidence the machine never rebooted); (ii) .operator ABSENT = NOT-KNOWN — this store predates the journal and CANNOT answer how many reboots there were (see absence/.operator, and the same state is restated as reboot-absence).  The boots-per-content number has its own absence: NO .bootlog (or an empty one) = NOT-KNOWN, never 0 boots" },
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
    { "runtime datalog rt_effect/rt_control", "/run/fx/log.db (fx-init init.zig:33 DEFAULT_RUN; path built :4663, opened :4664 by fx_log_open) — read by NOBODY here",
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
    { "nonce-binds-a-kernel-boot",
      "THE NONCE BINDS A KERNEL BOOT, NOT A PID1 LIFETIME (fx-init's SOFT REBOOT): PID1 re-enters its own boot path by execve, apply_kernel_nonce re-latches the SAME fx.bootnonce= on every re-entry (no kernel restarted), and the new lifetime appends its OWN in-progress and verdict for the SAME version under that same nonce.  So one nonce may legitimately carry MORE THAN ONE verdict pair for a version, and this seat's `boot-verdict` / `boot-start` rows will show them.  What separates that from the forged-pair shape is the ADMITTED <store>/.operator `reboot` row (action `reboot`, outcome ok, the same nonce, from-version = the generation re-judged) — ONE row per lifetime — and adjudicating it is fx-audit's job (its bound states the trade).  THIS SEAT CANNOT SEE THE DIFFERENCE: it reports both lines as MEASURED and prints the row; it does not decide whether the reboot was real.  A root forger in-guest can write a reboot row exactly as it can write a .bootlog line (§6b: the VM is the boundary), so 'there is a reboot row' is a RECORD, not proof — the same standing as every other row here." },
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
    { "reach-audit-is-the-weakened-one",
      "STATEMENT, not a bound to discover later: the reach class is the WEAKENED declared-vs-observed audit (plan Q5), NOT the type-enforced one round 1 would have given.  Because an egress call is JUDGED ARGUMENTS rather than typed, there is no per-generation DECLARATION for observed traffic to violate — so the strong direction ('observed traffic no declaration licenses') DOES NOT EXIST in this shape and this seat does not print it.  What survives is what the pinned tables and the log can honestly support: a stale GRANT (a pinned class row no observed call consumed) and PIN DRIFT (an artifact that is not the bytes PINS froze).  A reader must not read either finding as stronger than that" },
    { "reach-attribution-mirrors-the-seat",
      "the exercised direction attributes a class row to a call by MIRRORING three things from tools/fx-hostgate.c (file-static in a seat this unit may not touch): the lexical path canonicalizer, the two-form path matcher, and the authority normalizer + its two-form matcher.  MIRRORED, NOT SHARED — and that is the risk, named: a widening of the seat's matcher that this one does not follow would make a CONSUMED row read STALE (a false revocation question) or, in the other direction, an unexercised row read exercised.  The grammar itself cannot drift silently: eval_ops.py refuses any third pattern form at pin time, so both matchers are frozen by the pinned tables, not by this seat.  The MAPPING side is bounded too: --class-arg declares which key carries the classed argument, and an INCOMPLETE mapping can only under-attribute (NOT-KNOWN, or a false STALE) — it can never make a stale grant read exercised" },
    { "call-record-is-host-side",
      "the host proxy's ONE LOG (tools/fx-hostgate.c --log) and the guest's TRANSCRIPT (messages.jsonl) are named by the CALLER (--proxy-log / --transcript); neither has a store-sibling default, so the call class is UNARMED unless a side is named.  The reporter only READS both — byte-identical in, byte-identical out — and never re-renders or rewrites either.  The two sides are CHECKABLE against each other by call_id (the join key, never rewritten on either leg), NOT authoritative over each other: the log records what the MODEL said and what the host judged, the transcript records what CROSSED the gate (the rewritten name + a generic sentinel for a denial)" },
    { "call-auditing-not-proofing",
      "the call class is AUDITING, not PROOFING (design record §6b): the guest's transcript records the REWRITTEN name (the reserved fx_host_denied) and a generic sentinel for a denied call — it NEVER learns the true verb — so a denial is AUDITABLE only by joining the guest's view to the host's log by call_id, and this seat makes that join QUERYABLE rather than implicit.  This seat derives NOTHING about the judgement: it surfaces the verdict, the author and the refusal name VERBATIM and never classifies a word it does not own.  The echo telemetry records (unjoined-output, echo-anomaly, unresolved-substitution) are RECORDS, NOT TRIGGERS — NO LANE STOP BY DEFAULT (the deliberate demotion of round-1 G7's fail-closed tripwire): under H2 the teeth are STRUCTURAL (the true name never crossed), so a mismatch is a disagreement instrument, not an enforcement hole, and a hard stop would make the gate brittle against innocent sentinel changes" },
    { "sandbox-audit-is-the-weakened-one",
      "STATEMENT, not a bound to discover later: the sandbox class is the WEAKENED audit, exactly as the reach class is.  It compares TWO TEXTS — the composition the proxy would apply now and the spec each recorded host call applied — plus ONE pin (ops-sandbox.tsv).  It is NOT type-enforced: nothing forces a tool to declare what it uses, the sidecar is UNPINNED (any process that can write beside the tool binary can declare more, and that edit is invisible to PINS by construction), and the executor's baseline is a compile-time constant pinned by nothing but the binary it lives in.  The asymmetry is the audit's whole shape and it is stated rather than smoothed: because an operator row can only TIGHTEN, an ADDITION to the declaration can only come from the baseline or a sidecar, so a widening takes the loud side ALWAYS — a legitimate, deliberately-released sidecar widening is therefore a false positive this seat cannot distinguish, and saying so is cheaper than pretending the pin covers it.  What survives honestly: the difference is NAMED with its direction and its tokens, the operator table's pin is checked separately, and a missing side is NOT-KNOWN on every side" },
    { "sandbox-visible-is-not-strong",
      "a sandbox change being VISIBLE does not make the sandbox STRONG, and this report claims only the visibility.  The promises are COARSE: `inet` is ANY destination — the sandbox decides WHETHER sockets exist, never where they point, and the destination control is the operator's class tables (a different mechanism, with its own weakened audit).  The confinement is PER-PROCESS, not per-call: the spec is applied once, around the whole program, and the per-call data ceiling remains the deadline and the output cap.  There is no uid drop — stage3 keeps the host user.  And the spec reaching a wider set is not a claim about what the program DOES with it: the record shows what was declared and applied, never the syscalls a call made, which nothing in this family records" },
    { "activity-without-progress-cannot-see-intent",
      "THE MEASURE COUNTS COMMITS, NOT WORK, and it cannot know INTENT.  A repeated content identity may be a legitimate re-application of the same configuration after an unrelated repair (an operator repairing the disk and re-activating; an agent re-landing the config it already proved); a long, USEFUL task that published nothing at all looks perfectly FLAT here; and a single failure may be a typo already fixed.  So a FLAT reading is not a verdict on the agent's work, and a recurrence finding is not a verdict on its judgement: this seat says only 'new content was committed' or 'it was not'.  Whether the new content is BETTER is `osier-share`/the oracle (§7.1); whether it was INTENDED is the claim unit's judged record (§1a gap 2)" },
    { "progress-identity-is-content-not-behaviour",
      "the identity is the store's genhash, which CONTENT-ADDRESSES the config's PARSED fields plus the closure's store paths (fx-init zig/src/activate.zig:774-780, :1235) — it is NOT a behaviour hash.  Two configs that behave identically but move one parsed field produce DIFFERENT identities, and this seat calls the second PROGRESS; a comment-only edit does NOT move the key (activate.zig:1477-1490 keeps the genhash), which is the one thing it is trustworthy about and the reason an idempotent re-activation reads as a REPEAT rather than as work" },
    { "progress-verdict-join-mirrors-the-select-seat",
      "the per-version verdict (LAST non-`shutdown` .bootlog status in FILE ORDER, an UNRESOLVED `in-progress` tail counting as a failure) MIRRORS fx-select's viability term (tools/fx-select.c:755-768, the via_t last-non-shutdown rule) rather than sharing it — the same named risk the reach class carries as bound/reach-attribution-mirrors-the-seat — and the mirror is NOT EXACT, which is said here instead of being papered over: fx-select separates VIA_UNKNOWN / VIA_NEVER / VIA_TORN / VIA_DAMAGED and prefers the false stop on a line that is not the writer's field count, while this seat reads .bootlog through the report's ONE pre-existing parser (it REFUSES, exit 2, a line it cannot parse to three fields, but takes the status token of a parseable over-long line).  A drift between the two seats makes one call a version VIABLE while the other calls its content FAILED, and fx-init's guard_stats_for (zig/src/init.zig:1246) is the THIRD independent computation of the same quantity — which is why a divergence is a finding about the seats rather than a matter of taste" },
    { "progress-is-not-a-policy",
      "this class is a MEASUREMENT: it does not gate, deny, refuse, reorder or stop anything, and the report's own decision, candidate table and exit code are unchanged by a ratcheting store (the S4 precedent, egress-reach-widened/sandbox-reach-widened, proved that a loud row with a deliberately OPEN consequence is the house form).  Its recurrence threshold IS fx-init's RECOVERY_CONTENT_FAIL_MAX (zig/src/init.zig:1078, value 2) via guard_stats_for (:1246) — REUSED, NOT CHOSEN — because the boot guardrail ALREADY ACTS on exactly that count: a second actuator for one quantity would be a second policy with no owner, and the two could disagree silently.  The seat that GRADES must not be the seat that ACTS, and an instrument that can act has to be right, whereas a measurement may be incomplete provided it says so" },
    { "progress-cannot-see-a-changing-content-loop",
      "the recurrence finding fires on ONE identity failing again, and a loop that commits ALWAYS-NEW content and ALWAYS fails never reaches it: every identity fails exactly once, no count ever reaches the threshold, and the seat reports FULL PROGRESS over a wall of failures.  The boot guardrail misses that shape by construction too (its fail_n is per-genhash, so a fresh content always reads as transient).  The two numbers that describe it print beside the finding — `identities-never-ok` and `longest-failed-streak` — and NEITHER is a finding, deliberately: an honest debugging session (three configs tried, three failures, then the fix) produces exactly this shape, and a check that fires on the healthy path trains its reader to ignore it" },
    { "progress-blind-to-the-self-report",
      "the requirement's own 'or re-running the same task' half is UNMEASURABLE FROM THIS SEAT, and that is stated rather than approximated: a task re-run that published nothing left no store record, and the only record of it is the harness's attempts.jsonl — which this seat is FORBIDDEN to read (the file's header; pinned behaviourally by tests/test_fx_audit.sh's absent/planted/doctored byte-identity arm).  The moment a self-report can move this measure, an agent can talk the instrument out of a finding.  An INDEPENDENT record (the host's boot-nonce ledger is the candidate) is a SEPARATE unit, named here so the requirement's scope stays honest instead of appearing fully closed" },
    { "progress-record-scope",
      "the record is IN-GUEST WRITABLE: root inside the guest can forge or truncate <store>/.bootlog and edit the store's snapshots exactly as it can any other file, so this class inherits fx-select's bound `bootlog-is-in-guest-writable` BY CITATION (not restated).  Catching a forgery is fx-audit's job — it compares the record against its OWN previous observation — which is a different question, by design.  In the other direction, activity that reached neither the store nor .bootlog is invisible HERE: /run/fx/log.db is tmpfs (bound/rt-log-tmpfs), a nonce-less boot records nothing in .operator, and the three bypass paths bound/operator-bypass-paths names (a host-side `fxstore rollback`, `rollback --hard`, a hand-edited CURRENT) leave no attribution" },
    { "progress-version-cap",
      "MAX_VERSIONS (512) is hit exactly on this class's own subject — an oscillator ratchets versions forever — and the cap DIES LOUDLY (exit 2), which is correct and must NOT be softened into a partial measure.  The consequence is stated rather than hidden: in the very case this seat was built for, the measure becomes UNAVAILABLE and says so instead of reporting a truncated view.  Raising or streaming the cap is a separate decision with its own cost to measure (the precedent is bound/predecessor-content-not-compared, which records ~22 ms per `fxstore` call as the reason a whole-chain read was rejected there)" },
    { "reboot-visible-is-not-strong",
      "a reboot being VISIBLE in the journal does not make it a STRONG reboot, and this report claims only the visibility.  It is a USERSPACE RE-ENTRY: PID1 execve's /proc/self/exe and its own boot path runs again in a FRESH ADDRESS SPACE (that is what kills the forgotten-reset class), with NO firmware, NO device re-init and NO kernel restart — /dev, the virtio ports and every kernel-side resource are the ones the previous incarnation already had, so a device that WEDGED STAYS WEDGED and a reboot that would have fixed it will not.  A hard reboot is the HOST's act: under the pinned gates qemu carries -no-reboot, so reboot(2) makes the guest EXIT and the restart belongs to the host; kexec is not built into the guest kernel (MEASURED # CONFIG_KEXEC is not set) and would be a CAPABILITY WIDENING, not a convenience.  The agent is root and can forge or truncate every one of these rows (§6b: audit, not proof — the VM is the boundary)" },
    { "reboot-is-not-a-policy",
      "this class is a MEASUREMENT: it does not gate, deny, refuse, reorder or stop anything, and the report's decision and exit code move ONLY through the one finding below.  The ADMISSION lives in fx-init (operator_journal.zig's admit: the verdict latch, the open shell, REBOOT_SAME_VERSION_MAX) and runs in the guest; this seat reads what it RECORDED and cannot enforce, re-run or contradict it — a reboot row the admission would have refused is REPORTED, never undone.  The one FINDING fires when the record EXCEEDS the writer's own bound (consecutive admitted reboots at one from-version > REBOOT_SAME_VERSION_MAX), and its meaning is a writer WITHOUT that admission or a row written AROUND it — a question about the record, never a stop.  Its consequence is deliberately OPEN, the house form the egress and palisade slices set: a loud row, and nothing is changed by it" },
    { "reboot-row-records-the-admission",
      "the `reboot` row records the ADMISSION, never the EXECUTION (fx-init's own header: the row is written, fsync'd and the reply flushed BEFORE the exec, and there is no second row on an exec failure).  An ADMITTED reboot that never executed is therefore reconstructable only as the ABSENCE of a later .bootlog line carrying that row's nonce and a later epoch — a soft reboot re-enters under the SAME kernel boot's nonce (the command line does not change), so the row and the boot it produced are joined by NONCE PLUS ORDER, never by a unique token.  This class prints the `ok` rows and does NOT claim a boot happened: the boot count stays the .bootlog's, and the two numbers are read together" },
    { "reboot-cannot-see-a-changing-content-loop",
      "the structural stop bounds the SAME-VERSION loop only.  An ALWAYS-NEW-content loop (a new version each cycle, so every from-version differs) passes both of the admission's clauses by construction, and a reboot loop that publishes NOTHING moves no version and no run — so the ACTIVITY seat reads it perfectly FLAT.  The two numbers that describe that shape are PRINTED and deliberately NOT a finding: `boots-per-content-max` (joined to the content identity) and `consecutive-same-version-max`.  High activity with a high boots-per-content is the OSCILLATOR; high activity with a low one is a healthy loop.  Bounding that loop is the ORACLE's job (docs/baliveau-self-plan.md:629-640), not a reporter's, and a check here would fire on every honest debugging session — the same boundary the progress class drew for identities-never-ok" },
};
#define NBOUND (sizeof BOUNDS / sizeof BOUNDS[0])

/* ── THE CALL CLASS (P9): the host log <-> guest transcript join ───────── */

/* Emit a free-text field on a tab-separated record: tab / newline / carriage
 * return / backslash are escaped (the config-line convention) so a row
 * cannot be TORN by model-controlled text, and the value is emitted
 * VERBATIM otherwise — this seat never re-words a record it reads. */
static void emit_text(const char *s) {
    if (!s) { putchar('-'); return; }
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        switch (*p) {
        case '\\': fputs("\\\\", stdout); break;
        case '\t': fputs("\\t", stdout); break;
        case '\n': fputs("\\n", stdout); break;
        case '\r': fputs("\\r", stdout); break;
        default:
            if (*p < 0x20 || *p == 0x7f) printf("\\x%02x", *p);
            else putchar(*p);
        }
    }
}

static const char *jstr(yyjson_val *o, const char *k) {
    yyjson_val *v = yyjson_obj_get(o, k);
    return (v && yyjson_is_str(v)) ? yyjson_get_str(v) : NULL;
}

/* Render the turn field (an integer in the writer's shape, or absent). */
static void jturn(yyjson_val *o, long *out, int *set) {
    yyjson_val *v = yyjson_obj_get(o, "turn");
    if (v && yyjson_is_int(v)) { *out = (long)yyjson_get_sint(v); *set = 1; }
    else { *out = 0; *set = 0; }
}

/* The CLAIM: the justification the agent supplied, extracted from the call's
 * ARGUMENTS.  The args are a JSON string (the writer's `json_str`); the
 * justification is one property in it (the P5 tools schema makes it
 * required).  A call that carries none is `-absent` — a MEASUREMENT of the
 * args, not an error; args that are not JSON at all are named as such
 * rather than silently read as absent. */
static char *justification_of(const char *args) {
    if (!args || !args[0]) return xstrdup("-absent");
    yyjson_doc *d = yyjson_read(args, strlen(args), YYJSON_READ_NOFLAG);
    if (!d) return xstrdup("-unparseable-args");
    char *out = NULL;
    yyjson_val *o = yyjson_doc_get_root(d);
    if (yyjson_is_obj(o)) {
        const char *j = jstr(o, "justification");
        if (j) out = xstrdup(j);
    }
    yyjson_doc_free(d);
    return out ? out : xstrdup("-absent");
}

/* The verdict WORD, surfaced VERBATIM.  A word this seat does not know must
 * not be silently classified into the report's own vocabulary — the claim
 * class's discipline, carried.  This ONE line is what MUT-CALL-CLASSIFY
 * rewrites to reproduce the classification error. */
static const char *call_verdict_word(const char *v) { return v; }

/* The allowed row's own reading, carried VERBATIM (the P8 R5 finding: the
 * seat must never re-derive what a judge already wrote).  This ONE line is
 * what MUT-CALL-SCOPE rewrites to reproduce the re-derivation. */
static const char *call_scope_text(const hostcall_t *H) { return H->allow_scope; }

static int call_verdict_known(const char *v) {
    return !strcmp(v, "allowed") || !strcmp(v, "denied");
}

/* Read the host proxy's ONE LOG — append-only JSONL, one row per call.  The
 * reporter only READS it; it never re-renders or rewrites the file (the
 * gate asserts the bytes are unchanged after a report run). */
static void read_proxy_log(void) {
    if (!g_proxy_log) return;
    FILE *f = fopen(g_proxy_log, "r");
    if (!f) {
        if (errno == ENOENT) return; /* named but not there: absence is its own state */
        die("cannot read %s: %s (a read error is not an absence)", g_proxy_log, strerror(errno));
    }
    g_plog_present = 1;
    char *line = NULL;
    size_t cap = 0;
    ssize_t got;
    unsigned ln = 0;
    while ((got = getline(&line, &cap, f)) >= 0) {
        ln++;
        size_t l = (size_t)got;
        while (l && (line[l - 1] == '\n' || line[l - 1] == '\r')) line[--l] = 0;
        if (!l) continue; /* blank lines are not rows (the writer emits none) */
        if (l > MAX_LOG_LINE)
            die("%s:%u: row of %zu bytes exceeds the %u-byte cap — a report over a truncated row is a lie",
                g_proxy_log, ln, l, MAX_LOG_LINE);
        yyjson_doc *doc = yyjson_read(line, l, YYJSON_READ_NOFLAG);
        if (!doc)
            die("%s:%u: not JSON — a skipped row would silently drop a call from the account",
                g_proxy_log, ln);
        yyjson_val *o = yyjson_doc_get_root(doc);
        if (!yyjson_is_obj(o)) {
            yyjson_doc_free(doc);
            die("%s:%u: a row that is not a JSON object is not this log's grammar", g_proxy_log, ln);
        }
        const char *type = jstr(o, "type");
        if (!type) {
            const char *cid = jstr(o, "call_id");
            if (!cid) {
                yyjson_doc_free(doc);
                die("%s:%u: a row with neither `type` nor `call_id` is not this log's grammar",
                    g_proxy_log, ln);
            }
            if (g_nhcalls >= MAX_CALL_ROWS) {
                yyjson_doc_free(doc);
                die("%s: more than %u call rows — raise MAX_CALL_ROWS", g_proxy_log, (unsigned)MAX_CALL_ROWS);
            }
            hostcall_t *H = &g_hcalls[g_nhcalls++];
            memset(H, 0, sizeof *H);
            H->call_id = xstrdup(cid);
            jturn(o, &H->turn, &H->turn_set);
            const char *tn = jstr(o, "true_name");
            H->true_name = xstrdup(tn ? tn : "-");
            const char *aj = jstr(o, "args");
            H->args = aj ? xstrdup(aj) : NULL;
            H->justification = justification_of(aj);
            /* S4: THE EXECUTOR FIELD, carried VERBATIM and NEVER derived
             * from the registry (a name that later becomes a host tool —
             * or ceases to be one — would otherwise REWRITE the history of
             * old rows: a row carries ITS OWN reading of its scope, the
             * P6-fix R5 lesson). */
            const char *ex = jstr(o, "exec");
            H->exec = ex ? xstrdup(ex) : NULL;
            /* S4 (palisade): THE SANDBOX THE SPAWN APPLIED, carried VERBATIM.
             * It rides `exec` (the writer's rule: a sandbox reading only
             * exists on a row the host executed), so its absence on a host
             * row is NOT-KNOWN rather than "unsandboxed" — a pre-S3 proxy
             * wrote no spec, and this seat will not invent one for it. */
            const char *sbx = jstr(o, "sandbox");
            H->sandbox = sbx ? xstrdup(sbx) : NULL;
            yyjson_val *pv = yyjson_obj_get(o, "pending");
            H->pending = (pv && yyjson_is_bool(pv)) ? yyjson_get_bool(pv) : 0;
            const char *oc = jstr(o, "outcome");
            H->outcome = oc ? xstrdup(oc) : NULL;
            const char *vd = jstr(o, "verdict");
            H->verdict = vd ? xstrdup(vd) : NULL;
            const char *au = jstr(o, "author");       H->author = au ? xstrdup(au) : NULL;
            const char *as = jstr(o, "allow_scope");  H->allow_scope = as ? xstrdup(as) : NULL;
            const char *rn = jstr(o, "refusal_name"); H->refusal_name = rn ? xstrdup(rn) : NULL;
            const char *rs = jstr(o, "reason");       H->reason = rs ? xstrdup(rs) : NULL;
            H->lineno = ln;
        } else if (!strcmp(type, "unjoined-output") || !strcmp(type, "echo-anomaly") ||
                   !strcmp(type, "unresolved-substitution")) {
            if (g_ntele >= MAX_TELE_ROWS) {
                yyjson_doc_free(doc);
                die("%s: more than %u telemetry rows — raise MAX_TELE_ROWS", g_proxy_log, (unsigned)MAX_TELE_ROWS);
            }
            calltele_t *T = &g_tele[g_ntele++];
            memset(T, 0, sizeof *T);
            T->type = xstrdup(type);
            const char *cid = jstr(o, "call_id");
            T->call_id = xstrdup(cid ? cid : "-");
            /* unresolved-substitution carries `true_name`; the other two `output`. */
            const char *tx = jstr(o, !strcmp(type, "unresolved-substitution") ? "true_name" : "output");
            T->text = tx ? xstrdup(tx) : NULL;
            jturn(o, &T->turn, &T->turn_set);
            T->lineno = ln;
        } else if (!strcmp(type, "turn-stats") || !strcmp(type, "proxy-exit")) {
            /* terminal / aggregate rows: no call_id join, not this class */
        } else {
            yyjson_doc_free(doc);
            die("%s:%u: unknown row type \"%s\" — a newer proxy's row is not this seat's grammar "
                "(refused, never silently skipped)", g_proxy_log, ln, type);
        }
        yyjson_doc_free(doc);
    }
    if (ferror(f)) die("read error on %s: %s", g_proxy_log, strerror(errno));
    free(line);
    fclose(f);
}

static guestcall_t *guest_find(const char *call_id) {
    for (unsigned i = 0; i < g_nguest; i++)
        if (!strcmp(g_guest[i].call_id, call_id)) return &g_guest[i];
    return NULL;
}

/* Read the guest's transcripts (messages.jsonl): each line is a message
 * (checkpoint.c msg_to_json).  A call is recorded TWICE — the assistant's
 * tool_calls entry (id + the name that CROSSED the gate + the args) and the
 * role=tool result (tool_call_id + content, the sentinel) — joined on the id. */
static void read_transcript(void) {
    if (!g_transcript) return;
    FILE *f = fopen(g_transcript, "r");
    if (!f) {
        if (errno == ENOENT) return;
        die("cannot read %s: %s (a read error is not an absence)", g_transcript, strerror(errno));
    }
    g_tran_present = 1;
    char *line = NULL;
    size_t cap = 0;
    ssize_t got;
    unsigned ln = 0;
    while ((got = getline(&line, &cap, f)) >= 0) {
        ln++;
        size_t l = (size_t)got;
        while (l && (line[l - 1] == '\n' || line[l - 1] == '\r')) line[--l] = 0;
        if (!l) continue;
        if (l > MAX_LOG_LINE)
            die("%s:%u: message of %zu bytes exceeds the %u-byte cap — a report over a truncated message is a lie",
                g_transcript, ln, l, MAX_LOG_LINE);
        yyjson_doc *doc = yyjson_read(line, l, YYJSON_READ_NOFLAG);
        if (!doc)
            die("%s:%u: not JSON — a skipped message would silently drop a call from the account",
                g_transcript, ln);
        yyjson_val *o = yyjson_doc_get_root(doc);
        if (yyjson_is_obj(o)) {
            yyjson_val *tcs = yyjson_obj_get(o, "tool_calls");
            if (tcs && yyjson_is_arr(tcs)) {
                size_t idx, max;
                yyjson_val *tc;
                yyjson_arr_foreach(tcs, idx, max, tc) {
                    const char *id = jstr(tc, "id");
                    if (!id) continue;
                    guestcall_t *g = guest_find(id);
                    if (!g) {
                        if (g_nguest >= MAX_GUEST_ROWS) {
                            yyjson_doc_free(doc);
                            die("%s: more than %u recorded calls — raise MAX_GUEST_ROWS",
                                g_transcript, (unsigned)MAX_GUEST_ROWS);
                        }
                        g = &g_guest[g_nguest++];
                        memset(g, 0, sizeof *g);
                        g->call_id = xstrdup(id);
                        g->lineno = ln;
                    }
                    const char *nm = jstr(tc, "name");
                    if (nm && !g->name) g->name = xstrdup(nm);
                }
            }
            const char *role = jstr(o, "role");
            const char *tcid = jstr(o, "tool_call_id");
            if (role && !strcmp(role, "tool") && tcid) {
                guestcall_t *g = guest_find(tcid);
                if (!g) { /* a result with no recorded call (a truncated run) */
                    if (g_nguest >= MAX_GUEST_ROWS) {
                        yyjson_doc_free(doc);
                        die("%s: more than %u recorded calls — raise MAX_GUEST_ROWS",
                            g_transcript, (unsigned)MAX_GUEST_ROWS);
                    }
                    g = &g_guest[g_nguest++];
                    memset(g, 0, sizeof *g);
                    g->call_id = xstrdup(tcid);
                    g->lineno = ln;
                }
                if (!g->has_output) {
                    const char *c = jstr(o, "content");
                    g->output = xstrdup(c ? c : "-");
                    g->has_output = 1;
                }
            }
        }
        yyjson_doc_free(doc);
    }
    if (ferror(f)) die("read error on %s: %s", g_transcript, strerror(errno));
    free(line);
    fclose(f);
}

/* The call class's counters (the human summary reads them). */
static unsigned g_c_denied, g_c_allowed, g_c_nov, g_c_joined, g_c_hostonly,
    g_c_tranonly, g_c_disagree, g_c_tele, g_c_hostexec, g_c_guesexec,
    g_c_sbknown, g_c_sbunk;

static void emit_turn(long t, int set) {
    if (set) printf("%ld", t); else putchar('-');
}

/* A join-direction absence: its OWN row, its OWN stated meaning, and a
 * FINDING (the record SHOULD show the other side and does not).  `dir` is
 * the direction; `why` says which is absent and why that is not a zero. */
static void emit_join_absence(const char *call_id, const char *dir, const char *why) {
    printf("call-join\t%s\t%s\tFINDING\tbound\t%s\n", call_id, dir, why);
}

/* Emit the whole call class — the triple per judged call, the discrepancy
 * between the two records, the join's absences in BOTH directions, and the
 * telemetry rows. */
static void emit_calls(void) {
    int any = (g_proxy_log != NULL) || (g_transcript != NULL);

    for (unsigned i = 0; i < g_nhcalls; i++) {
        hostcall_t *H = &g_hcalls[i];
        guestcall_t *G = guest_find(H->call_id);

        /* the CLAIM: the justification that rode in with the call */
        printf("call-record\t%s\tturn\t", H->call_id);
        emit_turn(H->turn, H->turn_set);
        fputs("\ttrue-name\t", stdout);
        emit_text(H->true_name);
        fputs("\tjustification\t", stdout);
        emit_text(H->justification);
        fputs("\tMEASURED\n", stdout);

        /* S4: THE EXECUTOR DIMENSION — who RAN the call.  The row's `exec`
         * field is the proxy's own reading at row-creation time and it
         * renders ONLY on a host-executed call, so the dimension is
         * emitted for EVERY judged call, in both directions:
         *   present  -> MEASURED (the field is in the record);
         *   absent   -> DERIVED, and the derivation is the WRITER's stated
         *               grammar ("`exec` renders exactly when the HOST ran
         *               the call"), never a default this seat invented.  It
         *               is unambiguous only because host execution did not
         *               exist before the field did: a row carried verbatim
         *               from a pre-S1 log is a guest row BY CONSTRUCTION.
         * This is the seat §7.1a demands: an egress grant is a CAPABILITY
         * INCREASE, and a report that could not tell a host-executed call
         * from a guest one would be blind to exactly that increase. */
        if (H->exec) {
            fputs("call-exec\t", stdout);
            emit_text(H->call_id);
            fputs("\texec\t", stdout);
            emit_text(H->exec);
            /* S4 (palisade): THE SANDBOX IS A CAPABILITY, so it is a COLUMN
             * of the existing call row, not a second class (§7.1a: a spec IS
             * a capability declaration).  Three states, never conflated:
             *   the field  -> MEASURED, carried VERBATIM (what the spawn
             *                 ACTUALLY applied: promises + the effective
             *                 landlock, operator tightening included);
             *   no field   -> NOT-KNOWN (a host row from a pre-S3 proxy:
             *                 NOT "unsandboxed" and NOT "the baseline");
             *   no exec    -> - (a guest row: the writer renders a sandbox
             *                 spec only beside `exec`, so a guest row has
             *                 none BY CONSTRUCTION, not by omission). */
            fputs("\tsandbox\t", stdout);
            if (H->sandbox) emit_text(H->sandbox);
            else putchar('-');
            fputs("\tMEASURED\tthe row's OWN `exec` field: the HOST ran this call — a "
                  "declared program from the operator's pinned registry executed it on the "
                  "host and its bounded result was substituted over the guest's sentinel "
                  "(the capability the log exists to make visible, carried VERBATIM, never "
                  "re-derived from today's registry)", stdout);
            if (!H->sandbox)
                fputs("; the `sandbox` column is NOT-KNOWN for this row: the host ran it and "
                      "the row carries NO spec (a pre-S3 proxy wrote none) — never "
                      "'unsandboxed' and never 'the baseline'", stdout);
            g_c_hostexec++;
            if (H->sandbox) g_c_sbknown++; else g_c_sbunk++;
        } else {
            fputs("call-exec\t", stdout);
            emit_text(H->call_id);
            fputs("\texec\tguest\tsandbox\t-\tDERIVED\tthe row carries NO `exec` field, and the "
                  "writer's own grammar says it renders ONLY where the host ran the call — so "
                  "the GUEST executed this one (DERIVED from the record's shape, not from a "
                  "default; a row carried verbatim from a pre-S1 log is a guest row by "
                  "construction, because host execution did not exist then); a sandbox spec "
                  "rides `exec`, so a GUEST row has none BY CONSTRUCTION — not a missing "
                  "reading\n", stdout);
            g_c_guesexec++;
        }

        /* the VERDICT: the host's, with its author and refusal name.  NO
         * fabricated verdict — a row with no verdict field reads NOT-RECORDED. */
        if (!H->verdict) {
            printf("call-verdict\t%s\tverdict\t-\tNOT-RECORDED\tbound\t"
                   "no-verdict-field-no-policy-ran-on-this-call (NOT 'allowed')\n", H->call_id);
            g_c_nov++;
        } else {
            const char *w = call_verdict_word(H->verdict);
            printf("call-verdict\t%s\tverdict\t%s\tauthor\t", H->call_id, w);
            emit_text(H->author ? H->author : "-");
            fputs("\trefusal-name\t", stdout);
            emit_text(H->refusal_name ? H->refusal_name : "-");
            if (!strcmp(H->verdict, "allowed")) {
                /* the allowed row's OWN reading, VERBATIM (never re-derived) */
                fputs("\tallow-scope\t", stdout);
                emit_text(call_scope_text(H));
                g_c_allowed++;
            } else {
                fputs("\treason\t", stdout);
                emit_text(H->reason ? H->reason : "-");
                g_c_denied++;
            }
            fputs("\tMEASURED", stdout);
            if (!call_verdict_known(H->verdict))
                fputs("\tnote\tverdict-vocabulary-not-known-to-this-report-surfaced-verbatim-never-classified", stdout);
            putchar('\n');
        }

        /* the OUTCOME: what actually came back (the replayed
         * function_call_output the host observed) */
        if (H->outcome) {
            fputs("call-outcome\t", stdout);
            emit_text(H->call_id);
            fputs("\toutcome\t", stdout);
            emit_text(H->outcome);
            fputs("\tMEASURED\n", stdout);
        } else {
            printf("call-outcome\t%s\toutcome\t-\tNOT-RECORDED\tbound\t"
                   "%s-no-function_call_output-was-replayed-to-the-host (NOT an empty outcome)\n",
                   H->call_id, H->pending ? "pending-the-row-is-still-pending" : "unresolved");
        }

        /* the JOIN: absent in ONE direction is ITS OWN row; absent-in-neither
         * is the triple above plus the disagreement below. */
        if (G) {
            g_c_joined++;
            /* THE DISAGREEMENT IS THE INSTRUMENT: the guest recorded what
             * CROSSED the gate, the host recorded what the model said and
             * what it judged.  Two shapes: (a) the guest's name differs from
             * the host's true name — the rewrite, the gate working; (b) the
             * names AGREE while the host DENIED — the true name crossed a
             * call the host refused, a rewrite MISS (the silent-allow
             * direction), which the gate must be able to see.  Surfaced
             * VERBATIM, never classified into a vocabulary this seat does
             * not own. */
            int name_differs = G->name && strcmp(G->name, H->true_name) != 0;
            int crossed = G->name && !strcmp(G->name, H->true_name) &&
                          H->verdict && !strcmp(H->verdict, "denied");
            if (name_differs || crossed) {
                fputs("call-disagreement\t", stdout);
                emit_text(H->call_id);
                fputs("\thost-name\t", stdout);
                emit_text(H->true_name);
                fputs("\tguest-name\t", stdout);
                emit_text(G->name ? G->name : "-");
                fputs("\thost-verdict\t", stdout);
                emit_text(H->verdict ? H->verdict : "-");
                fputs("\thost-author\t", stdout);
                emit_text(H->author ? H->author : "-");
                fputs("\thost-refusal\t", stdout);
                emit_text(H->refusal_name ? H->refusal_name : "-");
                fputs("\tguest-output\t", stdout);
                emit_text(G->has_output ? G->output : "-");
                fputs("\tDERIVED\t", stdout);
                if (crossed)
                    fputs("the guest recorded the TRUE name for a call the host DENIED — "
                          "the guest accumulated what the rewriter was meant to replace, a "
                          "REWRITE MISS (the silent-allow direction)", stdout);
                else
                    fputs("the guest's transcript records what CROSSED the gate (the rewritten "
                          "name + a generic sentinel); the host log records what the MODEL said "
                          "and what the host judged — the divergence IS the record of the gate "
                          "working, verbatim from both records", stdout);
                putchar('\n');
                g_c_disagree++;
            }
        } else if (g_transcript) {
            /* the host judged a call the guest never recorded */
            emit_join_absence(H->call_id, "host-log-only",
                "the host decoded and judged this call; the guest transcript holds NO tool_call "
                "with this call_id (a rewrite miss, a crash, or a transcript from another run — "
                "NOT 'no call occurred')");
            g_c_hostonly++;
            g_findings++;
        }
    }

    /* the OTHER direction: the guest recorded a call the host never judged */
    if (g_proxy_log) {
        for (unsigned i = 0; i < g_nguest; i++) {
            guestcall_t *G = &g_guest[i];
            int in_log = 0;
            for (unsigned j = 0; j < g_nhcalls; j++)
                if (!strcmp(g_hcalls[j].call_id, G->call_id)) { in_log = 1; break; }
            if (in_log) continue;
            emit_join_absence(G->call_id, "transcript-only",
                "the guest recorded this call; the host log holds NO row for it (the proxy did "
                "not run for this span, or its log is from another run — NOT 'the host allowed it')");
            g_c_tranonly++;
            g_findings++;
        }
    }

    /* the ECHO TELEMETRY: the log's own anomaly rows, surfaced as records.
     * NO LANE STOP BY DEFAULT — the deliberate G7 demotion: under H2 the
     * teeth are STRUCTURAL (the true name never crossed), so a mismatch is a
     * disagreement instrument, not an enforcement hole, and a hard stop
     * would make the gate brittle against innocent sentinel changes.  These
     * rows therefore do NOT change this report's exit status. */
    for (unsigned i = 0; i < g_ntele; i++) {
        calltele_t *T = &g_tele[i];
        const char *meaning;
        if (!strcmp(T->type, "unjoined-output"))
            meaning = "the guest replayed a function_call_output whose call_id matches no call "
                      "the host ever decoded — the guest put words in the conversation; nothing "
                      "executed (bound/call-auditing-not-proofing)";
        else if (!strcmp(T->type, "echo-anomaly"))
            meaning = "a DENIED call's output is not one of the two known sentinels — the guest's "
                      "refusal shape changed; a disagreement recorded, never a trigger";
        else
            meaning = "a DENIED call whose outbound substitution never fired — the model would be "
                      "uninformed of the reason";
        fputs("call-telemetry\t", stdout);
        emit_text(T->type);
        fputs("\tcall_id\t", stdout);
        emit_text(T->call_id);
        fputs("\tturn\t", stdout);
        emit_turn(T->turn, T->turn_set);
        fputs("\toutput\t", stdout);
        emit_text(T->text);
        fputs("\tMEASURED\tnote\t", stdout);
        fputs(meaning, stdout);
        fputs(" — NO LANE STOP BY DEFAULT (the deliberate G7 demotion; these are records, not triggers)\n", stdout);
        g_c_tele++;
    }

    /* the two sides' own absences (the §1a gap-3 discipline at the join): a
     * side NOT given is NOT-KNOWN, never read as "no call". */
    if (any) {
        if (!g_proxy_log)
            printf("absence\tproxy-log\tnot-given-the-host-proxy-s-one-log-was-not-supplied-so-the-"
                   "host-side-of-the-call-join-is-NOT-KNOWN (NOT 'no call was judged')\tABSENT\n");
        else if (!g_plog_present)
            printf("absence\tproxy-log\tnot-durably-recorded-%s-does-not-exist-no-host-record-was-"
                   "produced-so-the-host-side-of-the-call-join-is-NOT-KNOWN (NOT 'no call was "
                   "judged')\tABSENT\n", g_proxy_log);
        if (!g_transcript)
            printf("absence\ttranscript\tnot-given-the-guest-transcript-messages-jsonl-was-not-"
                   "supplied-so-the-guest-side-of-the-call-join-is-NOT-KNOWN (NOT 'no call was "
                   "recorded')\tABSENT\n");
        else if (!g_tran_present)
            printf("absence\ttranscript\tnot-durably-recorded-%s-does-not-exist-no-guest-record-"
                   "was-produced-so-the-guest-side-of-the-call-join-is-NOT-KNOWN (NOT 'no call was "
                   "recorded')\tABSENT\n", g_transcript);
    }
}

/* ── S4: THE REACH CLASS — the weakened declared-vs-observed audit ────────
 *
 * WHERE THE "DECLARED" SIDE COMES FROM, stated as narrowly as it is true:
 * the operator's PINNED CLASS TABLES (--policy-dir) plus the PINS file that
 * freezes them.  NOT a type, NOT a per-generation declaration: because an
 * egress call is judged ARGUMENTS rather than typed, the "declared vs
 * observed" audit survives here only in its WEAKENED form (plan Q5).  The
 * strong direction round 1 would have given — an OBSERVED call that no
 * declaration licenses — does not exist in this shape, and this seat does
 * not pretend it does.
 *
 * WHAT THE TWO FINDINGS MEAN (each its own row, each its own meaning):
 *   stale-class-row  a pinned class row that NO observed call exercised —
 *                    a STALE GRANT: the operator granted a class (and
 *                    whether it is protected) and the log shows no call that
 *                    consumed it.  This is a REVOCATION question, not a
 *                    tamper: the grant is wider than the traffic.
 *   pin-drift        an artifact that no longer hashes to PINS — the table
 *                    the seat judged against is NOT the table the release
 *                    pinned.  Reported as a finding with BOTH pins, never
 *                    silently joined.
 *
 * HOW A ROW IS ATTRIBUTED TO A CALL, and the mirroring that makes it
 * honest: the call's classed argument is read out of the log row's args by
 * the KEY the CALLER declares (--class-arg DIM:TOOL=KEY — the registry's
 * arg_key is C, and this seat will NOT spell it a second time), the value is
 * normalized and matched against the row's pattern with the seat's OWN
 * grammar, MIRRORED here: the two-form path matcher plus the lexical
 * canonicalizer (fx-hostgate.c's fh_canon_abs/ops_pattern_hits) and the
 * authority normalizer plus its two-form matcher (authority_of/
 * host_pattern_hits).  MIRRORED, not shared — these are file-static in a
 * seat this unit may not touch — and that mirroring is the RISK, named: if
 * the seat's matcher ever widens, this one must follow or a consumed row
 * will read STALE (the harmless direction: a false revocation question) or,
 * worse, an unexercised row will read exercised.  The grammar itself is
 * frozen by the tables (eval_ops.py refuses any third form at pin time), so
 * the shape cannot drift silently under this seat.
 *
 * THE EXERCISED DIRECTION IS A MEASUREMENT ONLY WHEN BOTH SIDES ARE GIVEN
 * AND THE DIMENSION IS MAPPED — the §1a gap-3 discipline, once per side,
 * spelled out in the absence records the class emits.  No log, no policy
 * dir, or no --class-arg for the dimension that could consume the row is
 * NOT-KNOWN, NEVER "no call used it" and NEVER "stale". */

/* The lexical canonicalizer, MIRRORED from fx-hostgate.c's fh_canon_abs
 * (fx-verbs-server.c:388's canon_root_rel, the seat's own copy): collapse
 * '//', drop '.', resolve '..', refuse an escape or a relative path. */
static char *reach_canon_abs(const char *abs) {
    if (!abs || abs[0] != '/') return NULL;
    size_t cap = strlen(abs) + 2;
    char *out = xmalloc(cap);
    size_t olen = 0;
    int depth = 0;
    const char *p = abs;
    while (*p) {
        while (*p == '/') p++;
        if (!*p) break;
        const char *seg = p;
        while (*p && *p != '/') p++;
        size_t sl = (size_t)(p - seg);
        if (sl == 1 && seg[0] == '.') continue;
        if (sl == 2 && seg[0] == '.' && seg[1] == '.') {
            if (depth == 0) { free(out); return NULL; } /* escapes the root */
            while (olen > 0 && out[olen - 1] != '/') olen--;
            if (olen > 0) olen--;
            depth--;
            continue;
        }
        if (olen + sl + 2 >= cap) { free(out); return NULL; }
        out[olen++] = '/';
        memcpy(out + olen, seg, sl);
        olen += sl;
        depth++;
    }
    if (olen == 0) out[olen++] = '/'; /* the root itself */
    out[olen] = 0;
    return out;
}

/* The authority normalizer, MIRRORED from fx-hostgate.c's authority_of:
 * scheme dropped, host lowercased, port dropped; userinfo or no host returns
 * NULL (unclassable — it can attribute nothing to any row). */
static char *reach_authority_of(const char *url) {
    if (!url) return NULL;
    const char *scheme_end = strstr(url, "://");
    if (!scheme_end) return NULL;
    const char *p = scheme_end + 3;
    const char *slash = strchr(p, '/');
    const char *at = strchr(p, '@');
    if (at && (!slash || at < slash)) return NULL; /* userinfo: unclassable */
    const char *hostpart_end = slash ? slash : p + strlen(p);
    const char *colon = NULL;
    for (const char *q = p; q < hostpart_end; q++)
        if (*q == ':') { colon = q; break; }
    size_t host_len = colon ? (size_t)(colon - p) : (size_t)(hostpart_end - p);
    if (host_len == 0 || host_len > 255) return NULL;
    char *host = xmalloc(host_len + 1);
    memcpy(host, p, host_len);
    host[host_len] = 0;
    for (size_t i = 0; i < host_len; i++) {
        unsigned char c = (unsigned char)host[i];
        host[i] = (char)((c >= 'A' && c <= 'Z') ? c | 0x20 : c);
    }
    return host;
}

/* The PATH pattern matcher, MIRRORED from ops_pattern_hits: the two-form
 * grammar only — an EXACT path, or the SUBTREE form (the path plus a
 * trailing slash and two stars: the path and its descendants). */
static int reach_path_hits(const char *pattern, const char *canon) {
    size_t pl = strlen(pattern);
    if (pl >= 3 && strcmp(pattern + pl - 3, "/**") == 0) {
        size_t bl = pl - 3;
        size_t cl = strlen(canon);
        if (cl < bl || strncmp(canon, pattern, bl) != 0) return 0;
        return cl == bl || canon[bl] == '/';
    }
    return strcmp(canon, pattern) == 0;
}

/* The AUTHORITY pattern matcher, MIRRORED from host_pattern_hits: an EXACT
 * host, or '*.suffix' (exactly one label under the suffix). */
static int reach_host_hits(const char *pattern, const char *host) {
    size_t pl = strlen(pattern);
    if (pl >= 2 && pattern[0] == '*' && pattern[1] == '.') {
        const char *suffix = pattern + 2;
        size_t sl = strlen(suffix);
        size_t hl = strlen(host);
        if (hl > sl && host[hl - sl - 1] == '.' && strcmp(host + hl - sl, suffix) == 0)
            return 1;
        return 0;
    }
    return strcmp(pattern, host) == 0;
}

/* stat()-then-read: an ABSENT artifact and an UNREADABLE one are different
 * states, and a read error is not an absence (this file's every reader). */
static char *reach_slurp(const char *path, int *present) {
    struct stat st;
    *present = 0;
    if (stat(path, &st) != 0) {
        if (errno == ENOENT) return NULL;
        die("cannot stat %s: %s (a read error is not an absence)", path, strerror(errno));
    }
    *present = 1;
    size_t len = 0;
    char *b = slurp_file(path, &len);
    if (!b) die("cannot read %s: %s (a read error is not an absence)", path, strerror(errno));
    return b;
}

/* PINS: '#' comments + '<artifact><TAB><sha256>' rows.  A row this seat
 * cannot read is a LOUD failure, never a skipped line: a pin nobody read is
 * a pin nobody checked. */
static void reach_read_pins(void) {
    char path[4096];
    snprintf(path, sizeof path, "%s/PINS", g_policy_dir);
    char *b = reach_slurp(path, &g_pins_present);
    if (!b) return;
    char *save = NULL;
    for (char *line = strtok_r(b, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        size_t ll = strlen(line);
        if (ll && line[ll - 1] == '\r') line[--ll] = 0;
        if (!ll || line[0] == '#') continue;
        char *tab = strchr(line, '\t');
        if (!tab) die("%s: a PINS row is <artifact><TAB><sha256>: \"%s\"", path, line);
        *tab = 0;
        if (g_npins >= MAX_PIN_ROWS) die("%s: more than %u pin rows", path, (unsigned)MAX_PIN_ROWS);
        pinrow_t *P = &g_pins[g_npins++];
        memset(P, 0, sizeof *P);
        snprintf(P->name, sizeof P->name, "%s", line);
        snprintf(P->want, sizeof P->want, "%s", tab + 1);
        char apath[4096];
        snprintf(apath, sizeof apath, "%s/%s", g_policy_dir, P->name);
        int present = 0;
        char *ab = reach_slurp(apath, &present);
        P->present = present;
        if (ab) {
            size_t alen = strlen(ab);
            char sha[65];
            sha256_hex((const unsigned char *)ab, (unsigned)alen, sha);
            snprintf(P->got, sizeof P->got, "%s", sha);
            free(ab);
        }
    }
    free(b);
}

/* THE CLASS TABLES.  Two artifacts, two dimensions, one row shape: the
 * grant the operator wrote (pattern, class, protected).  ops-aliases.tsv's
 * columns are alias<TAB>pathclass<TAB>protected<TAB>pattern (the pattern is
 * the RUNTIME surface, last); ops-hosts.tsv's are
 * pattern<TAB>argclass<TAB>protected.  Rows are parsed, never validated
 * here — eval_ops.py validates at pin time and this seat reports what the
 * pinned table SAYS; a row it cannot parse is a loud failure, because a
 * skipped row is a grant that vanishes from the audit. */
static void reach_read_table(const char *table, int aliases) {
    char path[4096];
    snprintf(path, sizeof path, "%s/%s", g_policy_dir, table);
    int *present = aliases ? &g_alias_present : &g_hosts_present;
    char *b = reach_slurp(path, present);
    if (!b) return;
    g_reach_tables_read = 1;
    char *save = NULL;
    unsigned ln = 0;
    for (char *line = strtok_r(b, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        ln++;
        size_t ll = strlen(line);
        if (ll && line[ll - 1] == '\r') line[--ll] = 0;
        if (!ll || line[0] == '#') continue;
        char *f[4] = {0};
        int nf = 0;
        char *lsave = NULL;
        for (char *tok = strtok_r(line, "\t", &lsave); tok && nf < 4;
             tok = strtok_r(NULL, "\t", &lsave))
            f[nf++] = tok;
        const char *pattern, *cls, *prot;
        if (aliases) {
            if (nf != 4)
                die("%s:%u: a path-class row is alias<TAB>pathclass<TAB>protected<TAB>pattern "
                    "(eval_ops.py --check-aliases is the validator; this seat refuses to skip "
                    "a row it cannot read): \"%s\"", path, ln, line);
            pattern = f[3]; cls = f[1]; prot = f[2];
        } else {
            if (nf != 3)
                die("%s:%u: a host row is pattern<TAB>argclass<TAB>protected "
                    "(eval_ops.py --check-hosts is the validator; this seat refuses to skip a "
                    "row it cannot read): \"%s\"", path, ln, line);
            pattern = f[0]; cls = f[1]; prot = f[2];
        }
        if (g_nrrows >= MAX_REACH_ROWS) die("%s: more than %u class rows", path, (unsigned)MAX_REACH_ROWS);
        reachrow_t *R = &g_rrows[g_nrrows++];
        memset(R, 0, sizeof *R);
        R->table = xstrdup(table);
        R->pattern = xstrdup(pattern);
        R->cls = xstrdup(cls);
        R->prot = !strcmp(prot, "yes"); /* anything else reads not-protected: the
                                         * pin-time validator owns the vocabulary,
                                         * and no row reaches here unvalidated */
        R->lineno = ln;
    }
    free(b);
}

/* The call's classed argument, by the KEY the caller declared.  The args
 * text is the log row's own (the model's bytes, VERBATIM) and is parsed
 * here only to read one value out. */
static int call_classed_value(const hostcall_t *H, const char *key, char *out, size_t cap) {
    if (!H->args) return 0;
    yyjson_doc *d = yyjson_read(H->args, strlen(H->args), YYJSON_READ_NOFLAG);
    if (!d) return 0;
    int ok = 0;
    yyjson_val *o = yyjson_doc_get_root(d);
    if (yyjson_is_obj(o)) {
        yyjson_val *v = yyjson_obj_get(o, key);
        if (v && yyjson_is_str(v)) {
            snprintf(out, cap, "%s", yyjson_get_str(v));
            ok = 1;
        }
    }
    yyjson_doc_free(d);
    return ok;
}

/* WAS THE ROW EXERCISED by a call the log holds?  `*known` is 0 when the
 * direction cannot be measured at all (no log, or no declared mapping for
 * the dimension) — the caller then emits NOT-KNOWN, never "stale". */
static int reach_row_exercised(const reachrow_t *R, int aliases, int *known) {
    *known = 0;
    if (!g_proxy_log || !g_plog_present) return 0;   /* the observed side is absent */
    int mapped = 0;
    for (unsigned i = 0; i < g_nclassargs; i++)
        if (!strcmp(g_classargs[i].dim, aliases ? "path" : "authority")) mapped = 1;
    if (!mapped) return 0;                            /* the dimension is unmapped */
    *known = 1;
    for (unsigned i = 0; i < g_nhcalls; i++) {
        hostcall_t *H = &g_hcalls[i];
        for (unsigned c = 0; c < g_nclassargs; c++) {
            classarg_t *CA = &g_classargs[c];
            if (strcmp(CA->dim, aliases ? "path" : "authority")) continue;
            if (strcmp(CA->tool, H->true_name)) continue;
            char val[4096];
            if (!call_classed_value(H, CA->key, val, sizeof val)) continue;
            if (aliases) {
                char *canon = reach_canon_abs(val);
                if (canon) {
                    int hit = reach_path_hits(R->pattern, canon);
                    free(canon);
                    if (hit) return 1;
                }
            } else {
                char *host = reach_authority_of(val);
                if (host) {
                    int hit = reach_host_hits(R->pattern, host);
                    free(host);
                    if (hit) return 1;
                }
            }
        }
    }
    return 0;
}

/* Emit the reach class.  THREE ROW TAGS plus the TWO findings, each with
 * its own meaning, and one absence record per side that was not given. */
static void emit_reach(void) {
    if (!g_policy_dir && !g_proxy_log) return; /* unarmed: named in the usage */

    reach_read_pins();
    if (g_policy_dir) {
        reach_read_table("ops-aliases.tsv", 1);
        reach_read_table("ops-hosts.tsv", 0);
    }

    /* (1) THE DECLARED SIDE, SHA-NAILED: every artifact PINS names, with
     * the pin the release wrote and the bytes on disk now. */
    if (!g_policy_dir) {
        printf("absence\treach-declared\tnot-given-no---policy-dir-the-operator-s-pinned-"
               "class-tables-were-not-supplied-so-the-DECLARED-side-is-NOT-KNOWN (NOT "
               "'nothing is granted' and NOT 'every row is stale')\tABSENT\n");
    } else if (!g_pins_present) {
        printf("absence\treach-pins\tnot-durably-recorded-%s/PINS-does-not-exist-so-no-"
               "artifact-can-be-checked-against-a-pin (the pin-drift direction is "
               "NOT-KNOWN, never 'no drift')\tABSENT\n", g_policy_dir);
    } else {
        for (unsigned i = 0; i < g_npins; i++) {
            pinrow_t *P = &g_pins[i];
            const char *state;
            if (!P->present) state = "MISSING";
            else if (!strcmp(P->got, P->want)) state = "MATCH";
            else state = "DRIFT";
            printf("reach-pin\t%s\tsha\t%s\tpinned\t%s\t%s\t%s\n", P->name,
                   P->present ? P->got : "-", P->want, state,
                   P->present ? "MEASURED" : "DERIVED");
            if (!P->present) {
                printf("pin-drift\t%s\tsha\t-\tpinned\t%s\tFINDING\tDERIVED\tthe artifact "
                       "PINS names is NOT THERE — the table this seat is asked to judge "
                       "against is not the table the release pinned (and a release is "
                       "artifact + PINS in the SAME commit, so this cannot be a licensed "
                       "state)\n", P->name, P->want);
                g_findings++;
            } else if (strcmp(P->got, P->want) != 0) {
                printf("pin-drift\t%s\tsha\t%s\tpinned\t%s\tFINDING\tMEASURED\tthe artifact "
                       "on disk hashes to %s but PINS pins %s — the table the RELEASE "
                       "froze and the table this report reads are different bytes, so any "
                       "class row below is the CURRENT table's, not the pinned one's.  "
                       "Reported with BOTH pins; never silently joined\n",
                       P->name, P->got, P->want, P->got, P->want);
                g_findings++;
            }
        }
    }

    /* (2) THE CLASS ROWS, each a GRANT, with the exercised direction and the
     * §1a gap-3 discipline applied per side. */
    if (g_policy_dir) {
        if (!g_alias_present && !g_hosts_present)
            printf("absence\treach-tables\tnot-durably-recorded-neither-ops-aliases.tsv-nor-"
                   "ops-hosts.tsv-is-in-%s-so-there-is-NO-declared-class-row-to-audit "
                   "(NOT 'no class is granted')\tABSENT\n", g_policy_dir);
        unsigned n_stale = 0, n_unk = 0, n_yes = 0;
        for (unsigned i = 0; i < g_nrrows; i++) {
            reachrow_t *R = &g_rrows[i];
            int aliases = !strcmp(R->table, "ops-aliases.tsv");
            int known = 0;
            int hit = reach_row_exercised(R, aliases, &known);
            const char *state;
            if (hit) { state = "YES"; n_yes++; }
            else if (known) { state = "NO"; n_stale++; }
            else { state = "NOT-KNOWN"; n_unk++; }
            printf("reach-row\t%s\tline\t%u\tdimension\t%s\tpattern\t", R->table, R->lineno,
                   aliases ? "path" : "authority");
            emit_text(R->pattern);
            fputs("\tclass\t", stdout);
            emit_text(R->cls);
            printf("\tprotected\t%s\texercised\t%s\t%s\n", R->prot ? "yes" : "no", state,
                   hit ? "DERIVED"
                       : (known ? "DERIVED" : "ABSENT"));
            if (!strcmp(state, "NO")) {
                printf("stale-class-row\t%s\tline\t%u\tdimension\t%s\tpattern\t", R->table,
                       R->lineno, aliases ? "path" : "authority");
                emit_text(R->pattern);
                fputs("\tclass\t", stdout);
                emit_text(R->cls);
                printf("\tprotected\t%s\tFINDING\tDERIVED\ta STALE GRANT: the operator "
                       "pinned this class row (%s, protected=%s) and NO observed call in the "
                       "log consumed it.  WEAKENED AUDIT, stated: 'declared' here is the "
                       "pinned class table, NOT a per-generation type — this is a REVOCATION "
                       "question (a grant wider than the traffic), never a claim that "
                       "unlicensed traffic happened\n",
                       R->prot ? "yes" : "no",
                       aliases ? "a path class" : "an authority class",
                       R->prot ? "yes" : "no");
                g_findings++;
            }
        }
        (void)n_yes;
        if (g_nrrows == 0) {
            /* nothing to say beyond the absence rows above */
        } else if (n_unk)
            printf("reach-row-note\trows\t%u-unexercised-measured\t%u-not-known\tDEFERRED\t"
                   "a NOT-KNOWN row is one whose dimension no --class-arg declaration "
                   "covers, or whose observed side was not given: it is NEVER reported as "
                   "stale (the absence discipline, once per side)\n", n_stale, n_unk);
    }

    /* (3) THE MAPPINGS the caller declared, echoed so the record says what
     * the attribution rested on.  The registry's arg_key is C: this seat
     * takes it as an INPUT and its ABSENCE is NOT-KNOWN, never "this tool
     * has no classed argument". */
    if (!g_nclassargs)
        printf("absence\treach-class-arg\tnot-given-no---class-arg-DIM:TOOL=KEY-was-declared-"
               "so-no-call-s-classed-argument-can-be-attributed-and-every-row-reads-"
               "NOT-KNOWN (the registry's arg_key is C; this seat will not respell it, and "
               "an unmapped dimension is NOT 'no classed argument')\tABSENT\n");
    for (unsigned i = 0; i < g_nclassargs; i++)
        printf("reach-class-arg\t%s\ttool\t%s\tkey\t%s\tMEASURED\t(the DECLARED mapping this "
               "run was given: the registry's own arg_key is the truth and it is C — the "
               "mapping is an INPUT here, so an incomplete set can only make a row read "
               "NOT-KNOWN or, worst, STALE; it can never make a stale row read exercised)\n",
               g_classargs[i].dim, g_classargs[i].tool, g_classargs[i].key);
    (void)g_reach_tables_read;
}

/* ── S4 (PALISADE): THE SANDBOX CLASS — a spec IS a capability declaration ──
 *
 * §7.1a, in this tree's own words: "every oracle in the family must be able
 * to SEE capability changes ... otherwise the agent satisfies the oracle
 * while quietly widening what it can reach."  Since S3 the sandbox is
 * STRUCTURAL to the host executor: every spawn is wrapped, the BASELINE
 * belongs to the executor, a tool may declare MORE via a sidecar beside its
 * binary, and the operator's ops-sandbox.tsv row may only TIGHTEN.  So the
 * composed spec per tool is a capability declaration, and a change to any of
 * its parts is a CAPABILITY CHANGE that this seat must name.
 *
 * WHAT THIS SEAT CAN ACTUALLY COMPARE (and it is the WEAKENED shape, said
 * out loud rather than discovered later):
 *
 *   DECLARED NOW   the proxy's OWN composition: `--proxy BIN --print-sandbox`
 *                  prints name<TAB>promises<TAB>static-landlock per tool —
 *                  the executor's baseline + the tool's sidecar, rendered by
 *                  the same code the spawn uses.  This is the only way to
 *                  read the sidecar half WITHOUT respelling the C baseline.
 *   RECORDED THEN  the log's own per-call `sandbox` field: the spec the
 *                  spawn APPLIED, including the operator row's tightening
 *                  and the per-call judged path.  Never re-derived.
 *   PINNED         policy/ops/PINS over ops-sandbox.tsv — the OPERATOR half
 *                  only.  Nothing pins the sidecar and nothing pins the
 *                  executor's baseline, and that asymmetry is the whole
 *                  reason the RECORD comparison exists.
 *
 * THE DIRECTION THAT IS A FINDING IS NOT SYMMETRIC, and the asymmetry is
 * MEASURED, not assumed: --print-sandbox renders the DECLARATION (baseline +
 * sidecar) and is not touched by the operator table at all, while the
 * operator row can only tighten what the spawn applies.  So a promise/path
 * present in today's DECLARATION and absent from the RECORD is a change to
 * the baseline or the sidecar — and NEITHER OF THOSE HAS A PIN, so no
 * release can license it: that is `sandbox-widened-since-record`, a FINDING.
 * The mirror direction (the record carried something today's declaration
 * does not) is NAMED and is NOT a finding: an operator tightening produces
 * exactly that shape without any capability change.
 *
 * TWO DIRECTIONS OF ABSENCE, once per side, and no absence is ever read as
 * "unchanged": no --proxy = the DECLARED side is NOT-KNOWN (never "the
 * sandbox did not change"); no --proxy-log = the RECORDED side is NOT-KNOWN
 * (never "nothing ran under a wider spec"); no --policy-dir / no PINS / a
 * PINS that does not name ops-sandbox.tsv = the PIN direction is NOT-KNOWN
 * (never "the operator table is the released one").
 *
 * DO NOT OVERCLAIM: this audit is WEAKENED (pinned operator table + two
 * specs compared as TEXT), it is not type-enforced; and a sandbox change
 * being VISIBLE does not make the sandbox STRONG — the promises are COARSE
 * (`inet` is any destination), the confinement is PER-PROCESS and not
 * per-call, and there is no uid drop. */
#define MAX_SB_TOOLS 32
#define MAX_SB_OBS 128
#define MAX_SB_ENTRIES 64
#define SB_ARTIFACT "ops-sandbox.tsv"

typedef struct {
    char  name[128];
    char *promises;   /* the executor's baseline + the tool's sidecar */
    char *landlock;   /* the STATIC landlock (baseline loader+libc+sidecar) */
} sbtool_t;

typedef struct {
    char  tool[128];
    char *promises;   /* the recorded spec's promise tokens */
    char *landlock;   /* the recorded landlock, VERBATIM */
} sbobs_t;

static const char *g_proxy;      /* --proxy: the host proxy (--print-sandbox) */
static sbtool_t g_sbt[MAX_SB_TOOLS];
static unsigned g_nsbt;
static int g_sbt_known;          /* --print-sandbox answered */
static sbobs_t g_sbo[MAX_SB_OBS];
static unsigned g_nsbo;

/* Is `tok` in the space-separated `set`? */
static int sb_has_token(const char *set, const char *tok) {
    if (!set) return 0;
    size_t tl = strlen(tok);
    const char *p = set;
    for (;;) {
        while (*p == ' ' || *p == '\t') p++;
        if (!*p) return 0;
        const char *e = p;
        while (*e && *e != ' ' && *e != '\t') e++;
        if ((size_t)(e - p) == tl && !strncmp(p, tok, tl)) return 1;
        p = e;
    }
}

/* Split a spec "promises<space>landlock" into its two parts.  The promise
 * vocabulary is space-joined ALPHA tokens; the landlock is a `;`-joined list
 * of ABSOLUTE paths, so the first token containing '/' starts it.  Returns
 * malloc'd strings (either may be empty). */
static void sb_split_spec(const char *spec, char **promises, char **landlock) {
    const char *s = spec ? spec : "";
    const char *p = s;
    const char *cut = NULL;
    for (;;) {
        while (*p == ' ' || *p == '\t') p++;
        if (!*p) break;
        const char *e = p;
        while (*e && *e != ' ' && *e != '\t') e++;
        char tok[1024];
        size_t tl = (size_t)(e - p);
        if (tl >= sizeof tok) tl = sizeof tok - 1;
        memcpy(tok, p, tl);
        tok[tl] = 0;
        if (strchr(tok, '/')) { cut = p; break; }
        p = e;
    }
    if (cut) {
        size_t pl = (size_t)(cut - s);
        while (pl && (s[pl - 1] == ' ' || s[pl - 1] == '\t')) pl--;
        char *pr = xmalloc(pl + 1);
        memcpy(pr, s, pl); pr[pl] = 0;
        *promises = pr;
        *landlock = xstrdup(cut);
    } else {
        *promises = xstrdup(s);
        *landlock = xstrdup("");
    }
}

/* Run the proxy's own --print-sandbox.  A proxy that cannot answer is a LOUD
 * failure (exit 2), never "no tools" and never "no sandbox": reading a
 * failed probe as the narrower state is the one direction a capability
 * oracle must never fail in (the reach class's own rule). */
static void sb_read_composed(void) {
    if (!g_proxy) return;
    check_safe_path(g_proxy, "--proxy");
    char cmd[8192];
    snprintf(cmd, sizeof cmd, "'%s' --print-sandbox 2>/dev/null", g_proxy);
    FILE *p = popen(cmd, "r");
    if (!p) die("cannot run '%s --print-sandbox' (%s)", g_proxy, strerror(errno));
    char line[8192];
    int any = 0;
    while (fgets(line, sizeof line, p)) {
        line[strcspn(line, "\r\n")] = 0;
        if (!line[0]) continue;
        char *f[3] = {0};
        int nf = 0;
        char *save = NULL;
        for (char *tok = strtok_r(line, "\t", &save); tok && nf < 3;
             tok = strtok_r(NULL, "\t", &save))
            f[nf++] = tok;
        any = 1;
        if (nf < 2)
            die("'%s --print-sandbox' printed a row that is not name<TAB>promises<TAB>landlock: "
                "\"%s\" — a spec this seat cannot read is refused, never skipped", g_proxy, line);
        if (g_nsbt >= MAX_SB_TOOLS)
            die("'%s --print-sandbox' printed more than %u tools — raise MAX_SB_TOOLS",
                g_proxy, (unsigned)MAX_SB_TOOLS);
        sbtool_t *T = &g_sbt[g_nsbt++];
        snprintf(T->name, sizeof T->name, "%s", f[0]);
        T->promises = xstrdup(f[1]);
        T->landlock = xstrdup(nf > 2 ? f[2] : "");
    }
    int rc = pclose(p);
    if (rc != 0)
        die("'%s --print-sandbox' exited %d: the composed sandbox of the running host cannot "
            "be read, and reading a failed probe as 'no sandbox' would report the narrowest "
            "possible capability — a TOOL ERROR, never an empty composition", g_proxy, rc);
    if (!any)
        die("'%s --print-sandbox' printed NO tool: the proxy's closed registry cannot be "
            "empty, so this is a tool error, not a sandbox with nothing in it", g_proxy);
    g_sbt_known = 1;
}

/* THE RECORDED SIDE: each host-executed call's own spec, deduped by
 * (tool, spec) with a call count.  A host row with NO spec is kept as its
 * own state (NOT-KNOWN), never dropped and never read as "baseline only". */
static void sb_collect_recorded(void) {
    for (unsigned i = 0; i < g_nhcalls; i++) {
        hostcall_t *H = &g_hcalls[i];
        if (!H->exec) continue;                      /* a guest row has none */
        char *pr = NULL, *lk = NULL;
        if (H->sandbox) sb_split_spec(H->sandbox, &pr, &lk);
        unsigned seen = 0;
        for (unsigned j = 0; j < g_nsbo; j++)
            if (!strcmp(g_sbo[j].tool, H->true_name) &&
                !strcmp(g_sbo[j].promises ? g_sbo[j].promises : "-", pr ? pr : "-") &&
                !strcmp(g_sbo[j].landlock ? g_sbo[j].landlock : "-", lk ? lk : "-")) {
                seen = 1;
                break;
            }
        if (seen) { free(pr); free(lk); continue; }
        if (g_nsbo >= MAX_SB_OBS)
            die("more than %u distinct recorded sandbox specs — raise MAX_SB_OBS",
                (unsigned)MAX_SB_OBS);
        sbobs_t *O = &g_sbo[g_nsbo++];
        snprintf(O->tool, sizeof O->tool, "%s", H->true_name);
        O->promises = pr ? pr : xstrdup("-");
        O->landlock = lk ? lk : xstrdup("-");
    }
}

/* Count the recorded calls carrying one (tool, spec) pair. */
static unsigned sb_recorded_calls(const sbobs_t *O) {
    unsigned n = 0;
    for (unsigned i = 0; i < g_nhcalls; i++) {
        hostcall_t *H = &g_hcalls[i];
        if (!H->exec || strcmp(H->true_name, O->tool)) continue;
        char *pr = NULL, *lk = NULL;
        if (H->sandbox) sb_split_spec(H->sandbox, &pr, &lk);
        if (!strcmp(O->promises, pr ? pr : "-") &&
            !strcmp(O->landlock, lk ? lk : "-")) n++;
        free(pr); free(lk);
    }
    return n;
}

/* The entries of a `;`-joined list, as a set-membership test. */
static int sb_has_entry(const char *list, const char *e) {
    if (!list) return 0;
    size_t el = strlen(e);
    const char *p = list;
    for (;;) {
        const char *q = strchr(p, ';');
        size_t l = q ? (size_t)(q - p) : strlen(p);
        if (l == el && !strncmp(p, e, el)) return 1;
        if (!q) return 0;
        p = q + 1;
    }
}

/* THE DECOMPOSITION — and the SEAM it rests on, stated because a seam that
 * is guessed silently is how an audit goes blind.  The spawn renders the
 * effective landlock as "<resolved program>:rx;<static>;<judged path>:r",
 * where <static> is EXACTLY what --print-sandbox prints and the judged entry
 * exists only for a PATH tool whose call named a representable, existing path
 * the operator's row allows.  So the record can carry ONE trailing entry that
 * the declaration does not — and the baseline's own last entry (`libc:r`)
 * ENDS IN `:r` too, which is exactly the shape that made a naive "drop the
 * trailing :r" rule report a FALSE widening on an unchanged sandbox (MEASURED
 * in this unit's own first gate run).
 *
 * The rule here is therefore two-hypothesis and safe BY CONSTRUCTION for the
 * direction that matters: the record's entries are never silently KEPT out of
 * the comparison, only the record's own trailing entry may be EXCLUDED, and an
 * ADDITION is always an entry of the DECLARED side — so excluding a record
 * entry can create a false difference but can never HIDE one.  Between the two
 * hypotheses (with or without a trailing judged entry) the one with fewer
 * differences wins, and a tie keeps the entry.  Returns 0 when the record does
 * not even START with a "<abs program>:rx" entry: that is not the shape the
 * spawn renders, and it is named as such rather than re-read as "unchanged". */
static int sb_landlock_static(const char *recorded, const char *declared,
                              char **out_static) {
    char *buf = xstrdup(recorded ? recorded : "");
    char *ent[MAX_SB_ENTRIES];
    int n = 0;
    char *save = NULL;
    for (char *t = strtok_r(buf, ";", &save); t && n < MAX_SB_ENTRIES;
         t = strtok_r(NULL, ";", &save))
        ent[n++] = t;
    *out_static = NULL;
    if (n < 1) { free(buf); return 0; }
    size_t l0 = strlen(ent[0]);
    if (ent[0][0] != '/' || l0 < 4 || strcmp(ent[0] + l0 - 3, ":rx") != 0) {
        free(buf);
        return 0;
    }
    int last = n - 1;                       /* the candidate judged entry */
    size_t ll = strlen(ent[last]);
    int last_judged_shape = (n >= 2 && ent[last][0] == '/' && ll >= 3 &&
                             !strcmp(ent[last] + ll - 2, ":r"));
    /* diff count for the entries [1..upto) against the declared side */
    int best_upto = n, best = -1;
    for (int attempt = 0; attempt < 2; attempt++) {
        int upto = n;
        if (attempt == 1) {
            if (!last_judged_shape) break;
            upto = last;
        }
        int d = 0;
        for (int i = 1; i < upto; i++)
            if (!sb_has_entry(declared, ent[i])) d++;
        /* the declared side's entries the record does not carry */
        {
            char *dup = xstrdup(declared ? declared : ""), *sv = NULL;
            for (char *t = strtok_r(dup, ";", &sv); t; t = strtok_r(NULL, ";", &sv)) {
                int found = 0;
                for (int i = 1; i < upto; i++)
                    if (!strcmp(ent[i], t)) { found = 1; break; }
                if (!found) d++;
            }
            free(dup);
        }
        if (best < 0 || d < best) { best = d; best_upto = upto; }
    }
    struct tbuf { char *p; size_t len, cap; } t = {0};
    for (int i = 1; i < best_upto; i++) {
        size_t li = strlen(ent[i]);
        size_t need = t.len + li + 2;
        if (need > t.cap) {
            t.cap = need * 2;
            t.p = xrealloc(t.p, t.cap);
        }
        if (t.len) t.p[t.len++] = ';';
        memcpy(t.p + t.len, ent[i], li);
        t.len += li;
        t.p[t.len] = 0;
    }
    free(buf);
    if (!t.p) { *out_static = xstrdup(""); return 1; }
    *out_static = t.p;
    return 1;
}

/* Emit the sandbox class.  Armed only when at least one sandbox input is
 * present (the reach class's rule), so a run that never mentioned the
 * sandbox stays byte-identical. */
static void emit_sandbox(void) {
    if (!g_proxy && !g_sbt_known && !g_proxy_log && !g_policy_dir) return;

    sb_read_composed();
    sb_collect_recorded();

    /* (1) THE DECLARED SIDE, tool by tool — the proxy's own composition. */
    if (!g_proxy) {
        printf("absence\tsandbox-composed\tnot-given-no---proxy-so-the-DECLARED-composition-"
               "(baseline+sidecar,--print-sandbox)-was-not-read: the sandbox can be neither "
               "compared nor declared UNCHANGED (NOT 'the sandbox did not change' and NOT "
               "'nothing is declared')\tABSENT\n");
    } else {
        for (unsigned i = 0; i < g_nsbt; i++) {
            printf("sandbox-composed\t%s\tpromises\t", g_sbt[i].name);
            emit_text(g_sbt[i].promises);
            fputs("\tlandlock\t", stdout);
            emit_text(g_sbt[i].landlock);
            printf("\tMEASURED\tthe proxy's OWN composition (%s --print-sandbox): the "
                   "executor's baseline + this tool's sidecar, rendered by the same code "
                   "the spawn uses — the DECLARATION, before any operator tightening\n",
                   g_proxy);
        }
    }

    /* (2) THE RECORDED SIDE — what the log says each host call actually got. */
    if (!g_proxy_log || !g_plog_present) {
        printf("absence\tsandbox-recorded\tnot-given-no---proxy-log-(or-a-log-that-does-not-"
               "exist)-so-what-each-host-call-ACTUALLY-applied-is-NOT-KNOWN (NOT 'nothing "
               "ran under a wider spec' and NOT 'the sandbox did not change')\tABSENT\n");
    } else {
        int any = 0;
        for (unsigned i = 0; i < g_nsbo; i++) {
            sbobs_t *O = &g_sbo[i];
            any = 1;
            if (!strcmp(O->promises, "-")) {
                printf("sandbox-recorded\t%s\tcalls\t%u\tpromises\t-\tlandlock\t-\tNOT-KNOWN\t"
                       "bound\tthe host ran this call and the row carries NO `sandbox` field "
                       "(a pre-S3 proxy wrote none): the spec it applied is NOT-KNOWN here — "
                       "never 'unsandboxed' and never 'the baseline'\n",
                       O->tool, sb_recorded_calls(O));
                continue;
            }
            printf("sandbox-recorded\t%s\tcalls\t%u\tpromises\t", O->tool, sb_recorded_calls(O));
            emit_text(O->promises);
            fputs("\tlandlock\t", stdout);
            emit_text(O->landlock);
            fputs("\tMEASURED\tthe log's own `sandbox` field, carried VERBATIM: the spec the "
                  "spawn APPLIED (operator tightening and the per-call judged path included)\n",
                  stdout);
        }
        if (!any)
            printf("sandbox-recorded\t-\tcalls\t0\tnone\t-\tABSENT\tno-host-executed-call-in-this-"
                   "log-so-no-applied-spec-is-recorded-here (a MEASUREMENT of the log: NOT "
                   "'the sandbox was not applied' — every spawn is wrapped)\n");
    }

    /* (3) THE OPERATOR ARTIFACT'S PIN — the one pinned half. */
    {
        int pinned_line = 0;
        pinrow_t *P = NULL;
        for (unsigned i = 0; i < g_npins; i++)
            if (!strcmp(g_pins[i].name, SB_ARTIFACT)) { P = &g_pins[i]; pinned_line = 1; break; }
        if (!g_policy_dir) {
            printf("absence\tsandbox-pin\tnot-given-no---policy-dir-so-%s-and-PINS-were-not-"
                   "read: whether the operator's sandbox table is the RELEASED one is "
                   "NOT-KNOWN (never 'it is unchanged')\tABSENT\n", SB_ARTIFACT);
        } else if (!g_pins_present) {
            printf("absence\tsandbox-pin\tnot-durably-recorded-%s/PINS-does-not-exist-so-nothing-"
                   "pins-the-operator's-sandbox-table (the pin direction is NOT-KNOWN, never "
                   "'no edit')\tABSENT\n", g_policy_dir);
        } else if (!pinned_line) {
            printf("absence\tsandbox-pin\tnot-durably-recorded-%s/PINS-does-not-name-%s — this "
                   "release pins no operator sandbox table at all, so an edit to it is "
                   "invisible to the pin direction (NOT 'no edit')\tABSENT\n",
                   g_policy_dir, SB_ARTIFACT);
        } else {
            int sb_drift = P->present && strcmp(P->got, P->want) != 0;
            const char *state = !P->present ? "MISSING" : (sb_drift ? "DRIFT" : "MATCH");
            printf("sandbox-pin\t%s\tsha\t%s\tpin\t%s\t%s\t%s\n", SB_ARTIFACT,
                   P->present ? P->got : "-", P->want, state,
                   P->present ? "MEASURED" : "DERIVED");
            if (!P->present) {
                printf("sandbox-pin-drift\t%s\tsha\t-\tpin\t%s\tFINDING\tDERIVED\tthe operator "
                       "artifact PINS names is NOT THERE: the table that may TIGHTEN every "
                       "host tool's sandbox is gone, so the tightening the release froze "
                       "cannot be read (and a release is artifact + PINS in the SAME commit, "
                       "so this cannot be a licensed state)\n", SB_ARTIFACT, P->want);
                g_findings++;
            } else if (sb_drift) {
                printf("sandbox-pin-drift\t%s\tsha\t%s\tpin\t%s\tFINDING\tMEASURED\tthe operator "
                       "sandbox table hashes to %s but PINS pins %s — the tightening table "
                       "this run reads is NOT the one the release froze (reported with BOTH "
                       "pins; never silently joined)\n",
                       SB_ARTIFACT, P->got, P->want, P->got, P->want);
                g_findings++;
            }
        }
    }

    /* (4) THE DIFFERENCE — declared NOW against recorded THEN, one row per
     * tool, with the direction NAMED and only the widening direction a
     * FINDING (see the block comment: the operator table can only tighten). */
    if (!g_sbt_known || !g_proxy_log || !g_plog_present) {
        printf("sandbox-delta\t-\tNOT-KNOWN\tABSENT\t%s: a delta needs BOTH the DECLARED "
               "composition and the RECORDED specs, and 'no change' is NOT derivable from one "
               "reading\n",
               !g_sbt_known && g_proxy ? "the DECLARED side failed to be read"
               : (!g_proxy ? "the DECLARED side was not given (no --proxy)"
                           : "the RECORDED side was not given (no --proxy-log)"));
    } else {
        unsigned n_wide = 0, n_narr = 0, n_change = 0, n_shape = 0, n_none = 0;
        for (unsigned i = 0; i < g_nsbo; i++) {
            sbobs_t *O = &g_sbo[i];
            if (!strcmp(O->promises, "-")) continue;      /* NOT-KNOWN, named above */
            sbtool_t *T = NULL;
            for (unsigned j = 0; j < g_nsbt; j++)
                if (!strcmp(g_sbt[j].name, O->tool)) { T = &g_sbt[j]; break; }
            if (!T) {
                printf("sandbox-delta\t%s\tSHAPE\tDERIVED\tthe record shows an APPLIED spec for "
                       "a tool the current proxy's composition does not declare at all — the "
                       "registry or the composition changed; this seat names the difference "
                       "and does not guess which side moved\n", O->tool);
                n_shape++;
                continue;
            }
            /* promises: the token set difference, BOTH directions named */
            char added_tok[1024] = "", removed_tok[1024] = "";
            {
                char *dup = xstrdup(T->promises ? T->promises : "");
                char *sv = NULL;
                for (char *t = strtok_r(dup, " \t", &sv); t; t = strtok_r(NULL, " \t", &sv))
                    if (!sb_has_token(O->promises, t)) {
                        size_t l = strlen(added_tok);
                        snprintf(added_tok + l, sizeof added_tok - l, "%s%s", l ? " " : "", t);
                    }
                free(dup);
                dup = xstrdup(O->promises ? O->promises : "");
                sv = NULL;
                for (char *t = strtok_r(dup, " \t", &sv); t; t = strtok_r(NULL, " \t", &sv))
                    if (!sb_has_token(T->promises, t)) {
                        size_t l = strlen(removed_tok);
                        snprintf(removed_tok + l, sizeof removed_tok - l, "%s%s", l ? " " : "", t);
                    }
                free(dup);
            }
            /* landlock: the recorded static part against the declared one */
            char *rec_static = NULL;
            int shape_ok = sb_landlock_static(O->landlock, T->landlock, &rec_static);
            char added_lk[4096] = "", removed_lk[4096] = "";
            if (shape_ok) {
                char *dup = xstrdup(T->landlock ? T->landlock : "");
                char *sv = NULL;
                for (char *t = strtok_r(dup, ";", &sv); t; t = strtok_r(NULL, ";", &sv))
                    if (!sb_has_entry(rec_static, t)) {
                        size_t l = strlen(added_lk);
                        snprintf(added_lk + l, sizeof added_lk - l, "%s%s", l ? ";" : "", t);
                    }
                free(dup);
                dup = xstrdup(rec_static);
                sv = NULL;
                for (char *t = strtok_r(dup, ";", &sv); t; t = strtok_r(NULL, ";", &sv))
                    if (!sb_has_entry(T->landlock, t)) {
                        size_t l = strlen(removed_lk);
                        snprintf(removed_lk + l, sizeof removed_lk - l, "%s%s", l ? ";" : "", t);
                    }
                free(dup);
            }
            int has_add = added_tok[0] || added_lk[0];
            int has_rem = removed_tok[0] || removed_lk[0];
            if (!shape_ok) {
                printf("sandbox-delta\t%s\tSHAPE\tDERIVED\tthe recorded landlock does not START "
                       "with a \"<absolute program>:rx\" entry, so it is not the spec the "
                       "spawn renders: the recorded \"", O->tool);
                emit_text(O->landlock);
                printf("\" cannot be decomposed against today's declaration \"");
                emit_text(T->landlock);
                printf("\" — named as a shape difference, never re-read as 'unchanged'\n");
                n_shape++;
            } else if (!has_add && !has_rem) {
                n_none++;
            } else if (has_add && !has_rem) {
                printf("sandbox-delta\t%s\tWIDER\tDERIVED\tthe current DECLARATION grants what "
                       "the RECORD did not", O->tool);
                if (added_tok[0]) printf("; promise(s) added \"%s\"", added_tok);
                if (added_lk[0])  printf("; landlock entr(y/ies) added \"%s\"", added_lk);
                printf(".  The operator table can only TIGHTEN the applied spec and does not "
                       "touch --print-sandbox, so an addition here is a change to the "
                       "EXECUTOR BASELINE or to a tool's SIDECAR — and NEITHER has a pin: no "
                       "release can license it\n");
                printf("sandbox-widened-since-record\t%s\tFINDING\tDERIVED\tthe sandbox this host "
                       "would apply to %s is WIDER than the spec the log recorded it applying "
                       "(%s); the composed spec is a CAPABILITY DECLARATION and its baseline "
                       "and sidecar are UNPINNED, so this is a capability change nothing "
                       "released.  WEAKENED AUDIT, stated: two specs compared as text, never "
                       "the type-enforced shape\n",
                       O->tool, O->tool, g_proxy_log);
                g_findings++;
                n_wide++;
            } else if (!has_add && has_rem) {
                printf("sandbox-delta\t%s\tNARROWER\tDERIVED\tthe RECORD carried what the "
                       "current DECLARATION does not", O->tool);
                if (removed_tok[0]) printf("; promise(s) \"%s\"", removed_tok);
                if (removed_lk[0])  printf("; landlock entr(y/ies) \"%s\"", removed_lk);
                printf(".  NOT a finding, and the ambiguity is NAMED rather than adjudicated: "
                       "an operator %s row (DENY-MORE-ONLY) produces exactly this shape at "
                       "spawn time without any capability change, and so does a revocation "
                       "since the call — this seat reports the direction and does not pretend "
                       "to know which\n", SB_ARTIFACT);
                n_narr++;
            } else {
                printf("sandbox-delta\t%s\tCHANGED\tDERIVED\tthe declaration and the record differ "
                       "BOTH ways", O->tool);
                if (added_tok[0] || added_lk[0])
                    printf("; added now \"%s%s%s\"", added_tok,
                           added_tok[0] && added_lk[0] ? " " : "", added_lk);
                if (removed_tok[0] || removed_lk[0])
                    printf("; gone now \"%s%s%s\"", removed_tok,
                           removed_tok[0] && removed_lk[0] ? " " : "", removed_lk);
                printf(" — the addition is the widening half and is raised as a finding; the "
                       "removal is named and is not\n");
                printf("sandbox-widened-since-record\t%s\tFINDING\tDERIVED\tthe sandbox this host "
                       "would apply to %s ADDS capability the log's recorded spec did not carry "
                       "(%s)%s\n", O->tool, O->tool, g_proxy_log,
                       added_tok[0] || added_lk[0] ? "" : " — no addition survived decomposition, "
                                                          "so no widening is claimed");
                if (added_tok[0] || added_lk[0]) g_findings++;
                n_change++;
            }
            free(rec_static);
        }
        /* THE PER-TOOL BLIND, named rather than left to be found: a tool the
         * proxy declares but the log never recorded has NOTHING to compare
         * against, so its spec change cannot be named HERE (fx-audit's
         * per-boot record does cover it: it reads the composition every
         * run).  NOT-KNOWN, never "unchanged". */
        for (unsigned j = 0; j < g_nsbt; j++) {
            int recorded = 0;
            for (unsigned i = 0; i < g_nsbo; i++)
                if (!strcmp(g_sbo[i].tool, g_sbt[j].name) && strcmp(g_sbo[i].promises, "-"))
                    recorded = 1;
            if (recorded) continue;
            printf("sandbox-delta\t%s\tNOT-KNOWN\tABSENT\tthe composition declares this tool and "
                   "NO host-executed call in the log carries an applied spec for it: its sandbox "
                   "cannot be compared here (never 'unchanged') — a per-CALL record can only "
                   "speak about the tools the calls exercised, which is why fx-audit records the "
                   "whole composition per boot\n", g_sbt[j].name);
        }
        if (!g_nsbo)
            printf("sandbox-delta\t-\tNOT-KNOWN\tABSENT\tno host-executed call in the log carries "
                   "an applied spec, so there is nothing to compare the declaration against — "
                   "NOT 'the sandbox did not change'\n");
        else if (!n_wide && !n_narr && !n_change && !n_shape)
            printf("sandbox-delta\t-\tNONE\tDERIVED\tthe composed declaration and EVERY recorded "
                   "applied spec agree token-for-token and entry-for-entry (promises and the "
                   "static landlock, with the per-call program :rx and judged :r entries "
                   "excluded): no sandbox change BETWEEN THIS DECLARATION AND THIS RECORD — a "
                   "measurement about the two readings, never a claim about the whole fleet\n");
        if (n_wide || n_change || n_shape)
            printf("sandbox-change-note\twider\t%u\tnarrower\t%u\tchanged\t%u\tshape\t%u\tDERIVED\t"
                   "a sandbox change is a CAPABILITY change (§7.1a) and it is NAMED here; the "
                   "sandbox is still not STRONG: promises are COARSE (`inet` is any "
                   "destination), the confinement is PER-PROCESS and not per-call, and there "
                   "is no uid drop\n", n_wide, n_narr, n_change, n_shape);
        (void)n_none;
    }
}

/* --class-arg DIM:TOOL=KEY — the declared bridge from a call's tool to the
 * argument the registry classes.  LOUD on any shape it does not know: a
 * dimension this seat cannot judge must not be silently dropped (a dropped
 * mapping reads as NOT-KNOWN at best and as a stale grant at worst). */
static void add_classarg(const char *spec) {
    const char *colon = strchr(spec, ':');
    const char *eq = strchr(spec, '=');
    if (!colon || !eq || colon > eq || colon == spec || eq == colon + 1 || !eq[1])
        die("--class-arg is DIM:TOOL=KEY (e.g. path:host_cat=path): \"%s\"", spec);
    char dim[32], tool[128], key[128];
    snprintf(dim, sizeof dim, "%.*s", (int)(colon - spec), spec);
    snprintf(tool, sizeof tool, "%.*s", (int)(eq - colon - 1), colon + 1);
    snprintf(key, sizeof key, "%s", eq + 1);
    if (strcmp(dim, "path") && strcmp(dim, "authority"))
        die("--class-arg dimension \"%s\" is not one this seat judges (path|authority) — the "
            "two pinned class tables are the two dimensions that exist", dim);
    if (g_nclassargs >= MAX_CLASSARGS)
        die("more than %u --class-arg declarations", (unsigned)MAX_CLASSARGS);
    for (unsigned i = 0; i < g_nclassargs; i++)
        if (!strcmp(g_classargs[i].dim, dim) && !strcmp(g_classargs[i].tool, tool))
            die("--class-arg declares \"%s\" twice for tool %s — a second spelling of the "
                "same mapping is a mapping nobody can trust", dim, tool);
    classarg_t *CA = &g_classargs[g_nclassargs++];
    CA->dim = xstrdup(dim);
    CA->tool = xstrdup(tool);
    CA->key = xstrdup(key);
}

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

/* ── THE PROGRESS CLASS — MEASURE ACTIVITY WITHOUT PROGRESS ──────────────
 *    (§1's last owed seat; design record §1a's taxonomy, requirement
 *    todo.md §1.)  A MEASUREMENT, never a policy: it gates, denies, refuses
 *    and stops NOTHING.
 *
 * ACTIVITY = published versions split by CONTENT IDENTITY — the store's own
 * `generation` genhash, read into version_t.genhash by read_facts (:672) —
 * and NOT by the version number.  The version number is inflated by two
 * things that must never be conflated with work: the publish PROTOCOL's own
 * duplicate of the immediately-preceding generation (one per fx-activate run
 * after the first — the same `republish-live` the activation event already
 * classifies, :3104-3107) and an idempotent re-activation of identical bytes
 * (fx-init KEEPS the genhash when a config edit does not move a parsed field,
 * activate.zig:1477-1490, while fxstore's publish is unconditional).
 *
 * PROGRESS = the FIRST SIGHTING of a content identity.  A repeat is zero
 * progress BY DEFINITION: same content, new number.
 *
 * The identity key is 64 hex bytes and a longer genhash is a LOUD die: a
 * TRUNCATED key either merges two identities (hiding a repeat) or splits one
 * (hiding the identity) — silently, in the same direction this class exists
 * to refuse.  Nothing here reads attempts.jsonl or any harness self-report. */
typedef struct {
    char genhash[65];        /* the content identity; "-" = NOT-KNOWN */
    unsigned versions;       /* published versions carrying it */
    unsigned runs;           /* MAXIMAL consecutive runs of them */
    unsigned repeats;        /* versions after the first carrying it */
    unsigned benign_repeats; /* of those, the immediately-preceding version
                              * (the publish protocol's own pair) */
    unsigned failed;         /* last non-shutdown verdict `failed` */
    unsigned inprog;         /* ... `in-progress` (an UNRESOLVED boot) */
    unsigned ok;             /* ... `ok` */
    unsigned ok_noncur;      /* ... `ok`, excluding the CURRENT version */
    unsigned notjudged;      /* no non-shutdown .bootlog line at all */
    unsigned other;          /* a status word outside the writer's set */
    unsigned boots;          /* `in-progress` .bootlog lines on its versions:
                              * boots that STARTED at this content */
    unsigned first_v, last_v;
    int live;                /* its last version IS the CURRENT one */
    int known;               /* 0 for the "-" identity */
} ident_t;

static ident_t g_idents[MAX_IDENTS];
static unsigned g_nidents;

/* THE VERDICT JOIN: per version, the LAST non-`shutdown` .bootlog status in
 * FILE ORDER.  MEASURED rule, fx-init's own (init.zig:1115-1127, bootver_apply): raw entry
 * counting false-positives — an `in-progress` later RESOLVED to `ok` must read
 * ok — while an UNRESOLVED `in-progress` tail (a crash mid-boot) is exactly the
 * evidence the recovery trigger reads as a stale failure.  `shutdown` is not a
 * verdict.  NULL when the version has no non-shutdown line. */
static const char *verdict_of(unsigned v) {
    const char *st = NULL;
    for (unsigned i = 0; i < g_nbl; i++)
        if (g_bl[i].v == v && strcmp(g_bl[i].status, "shutdown") != 0) st = g_bl[i].status;
    return st;
}

/* REUSED, NOT CHOSEN: the recurrence threshold IS fx-init's
 * RECOVERY_CONTENT_FAIL_MAX (fixpoint-linux/fx-init zig/src/init.zig:1078,
 * value 2 — "2, not 1: a single failure must still recover exactly as today;
 * only the REPEAT is evidence of a persistent fault rather than a transient
 * one").  The boot guardrail already ACTS on exactly this count through
 * guard_stats_for (:1246: fail_n = distinct published versions carrying the
 * genhash whose LAST non-shutdown .bootlog status is failed or in-progress),
 * so this seat and the boot path compute the SAME quantity under the SAME
 * threshold from the SAME records, INDEPENDENTLY — a divergence between them
 * is a finding about the seats, not a matter of taste.  This seat only
 * REPORTS it; it never refuses, denies or stops anything. */
#define PROGRESS_CONTENT_FAIL_MAX 2

static void build_identities(unsigned cur_v) {
    for (unsigned i = 0; i < g_nvers; i++) {
        version_t *V = &g_vers[i];
        size_t gl = strlen(V->genhash);
        if (gl >= sizeof g_idents[0].genhash)
            die("version %u's genhash is %zu bytes — the content-identity key is %zu (64 hex); "
                "a TRUNCATED key would MERGE or SPLIT identities, which is exactly the blindness "
                "this class refuses", V->v, gl, sizeof g_idents[0].genhash - 1);
        ident_t *I = NULL;
        for (unsigned k = 0; k < g_nidents; k++)
            if (!strcmp(g_idents[k].genhash, V->genhash)) { I = &g_idents[k]; break; }
        if (!I) {
            if (g_nidents >= MAX_IDENTS)
                die("more than %u distinct content identities — raise MAX_IDENTS (a partial "
                    "measure is a lie)", (unsigned)MAX_IDENTS);
            I = &g_idents[g_nidents++];
            memset(I, 0, sizeof *I);
            snprintf(I->genhash, sizeof I->genhash, "%s", V->genhash);
            I->first_v = V->v;
            I->known = strcmp(V->genhash, "-") != 0;
        } else {
            I->repeats++;
            if (i > 0 && !strcmp(g_vers[i - 1].genhash, V->genhash)) I->benign_repeats++;
        }
        I->versions++;
        I->last_v = V->v;
        I->live = (V->v == cur_v);
        if (i == 0 || strcmp(g_vers[i - 1].genhash, V->genhash) != 0) I->runs++;
        /* the REBOOT class's denominator: how many boots STARTED at this
         * content (one `in-progress` line each, init.zig's bootlog_append).
         * Counted HERE because this is the only place a version is joined to
         * its identity — the same join fx-init's guard_stats_for uses. */
        for (unsigned b = 0; b < g_nbl; b++)
            if (g_bl[b].v == V->v && !strcmp(g_bl[b].status, "in-progress")) I->boots++;
        const char *st = verdict_of(V->v);
        if (!st) I->notjudged++;
        else if (!strcmp(st, "ok")) { I->ok++; if (V->v != cur_v) I->ok_noncur++; }
        else if (!strcmp(st, "failed")) I->failed++;
        else if (!strcmp(st, "in-progress")) I->inprog++;
        else I->other++;
    }
}

/* the identity row's own classification.  `benign-publish-pair` is its OWN
 * word (never `repeat-of`): it says the only reason the version count
 * exceeds the run count is the publish protocol. */
static void ident_class(const ident_t *I, char *buf, size_t n) {
    if (!I->known) snprintf(buf, n, "not-known");
    else if (I->versions == 1) snprintf(buf, n, "new");
    else if (I->repeats == I->benign_repeats) snprintf(buf, n, "benign-publish-pair");
    else snprintf(buf, n, "repeat-of-%u", I->first_v);
}

static void emit_progress(void) {
    for (unsigned k = 0; k < g_nidents; k++) {
        ident_t *I = &g_idents[k];
        char cls[64];
        ident_class(I, cls, sizeof cls);
        printf("progress-content\t%s\tversions\t%u\truns\t%u\tfailed\t%u\tin-progress\t%u"
               "\tok\t%u\tnot-judged\t%u\tother\t%u\tfirst-version\t%u\tlast-version\t%u"
               "\tlive\t%s\tclassification\t%s\tMEASURED\n",
               I->genhash, I->versions, I->runs, I->failed, I->inprog, I->ok, I->notjudged,
               I->other, I->first_v, I->last_v, I->live ? "yes" : "no", cls);
    }
    /* THE FINDING: the SAME content published and judged failed again.  It is
     * a RECORD, not a verdict on intent — "THE SAME FAULT RETURNING, not proof
     * of a live loop" (outcome.c:1106's wording, reused rather than re-coined),
     * and the bound that says so travels INLINE on the row, where a reader
     * meets the number. */
    for (unsigned k = 0; k < g_nidents; k++) {
        ident_t *I = &g_idents[k];
        if (!I->known) continue; /* NOT-KNOWN is never a count of anything */
        unsigned fail_v = I->failed + I->inprog;
        if (fail_v < PROGRESS_CONTENT_FAIL_MAX) continue;
        printf("progress-finding\tactivity-without-progress-recurrence\tgenhash\t%s"
               "\tversions\t%u\tfailed\t%u\tfirst-version\t%u\tlast-version\t%u\tlive\t%s"
               "\tbound\tactivity-without-progress-cannot-see-intent\tMEASURED\t"
               "the same content has been published and judged failed %u time(s) — THE SAME "
               "FAULT RETURNING, not proof of a live loop (this seat runs when it runs, so a "
               "recurrence in the RECORD is not a live oscillation); `failed` here is "
               "failed(%u)+in-progress(%u) last verdicts, i.e. EXACTLY fx-init's "
               "guard_stats_for fail_n under RECOVERY_CONTENT_FAIL_MAX=2 "
               "(zig/src/init.zig:1078,:1246) — REUSED, NOT CHOSEN; the boot guardrail ACTS on "
               "it and this seat only REPORTS it (bound/progress-is-not-a-policy).  It cannot "
               "know INTENT: this may be a deliberate re-application of the same configuration "
               "after an unrelated repair\n",
               I->genhash, I->versions, fail_v, I->first_v, I->last_v, I->live ? "yes" : "no",
               fail_v, I->failed, I->inprog);
        g_findings++;
    }
}

/* AXIS 2 — the loop shape the recurrence finding above CANNOT see: every
 * iteration commits NEW content and every one fails, so no identity ever
 * reaches fail_n=2 and the seat would report FULL PROGRESS over a wall of
 * failures.  Both numbers are READ, never judged, and neither is ever a
 * finding: a normal debugging session (three configs, three failures, then
 * the fix) has exactly this shape, and a check that fires on the honest path
 * trains its reader to ignore it. */
static unsigned identities_never_ok(void) {
    unsigned n = 0;
    for (unsigned k = 0; k < g_nidents; k++) {
        ident_t *I = &g_idents[k];
        if (!I->known) continue;
        /* CURRENT is EXCLUDED and says so: a boot verdict arrives one boot
         * LATER than the state it judges (fx-select's own `current-not-judged`
         * withhold state), so a healthy store's newest identity has no verdict
         * yet — counting it would fire on every healthy machine. */
        if (I->versions - (I->live ? 1u : 0u) == 0) continue;
        if (I->ok_noncur == 0) n++;
    }
    return n;
}

static unsigned longest_failed_streak(void) {
    unsigned best = 0, run = 0;
    for (unsigned i = 0; i < g_nvers; i++) {
        version_t *V = &g_vers[i];
        if (!strcmp(V->genhash, "-")) continue; /* NOT-KNOWN is not a commit */
        if (i > 0 && !strcmp(g_vers[i - 1].genhash, V->genhash))
            continue; /* the protocol's own pair is not a second commit */
        const char *st = verdict_of(V->v);
        if (st && (!strcmp(st, "failed") || !strcmp(st, "in-progress"))) {
            if (++run > best) best = run;
        } else run = 0;
    }
    return best;
}

/* ── THE REBOOT CLASS — THE IN-GUEST REBOOT, MEASURED FROM ITS OWN ROWS ──
 *    (todo.md §4's last slice; plan handoff-reboot-plan, its S4).  A
 *    MEASUREMENT exactly as ACTIVITY is: it gates, denies, refuses and
 *    stops NOTHING.
 *
 * THE RECORD IS fx-init's `.operator` `reboot` row (its ctrl arm, fx-init
 * bb0642f), already parsed by read_operator (:827) — no new reader and no
 * new file: <epoch> reboot <reason> <outcome> <from-version> - <nonce>.  The
 * outcome vocabulary is the WRITER's header (fx-init
 * zig/src/operator_journal.zig:165-215) and it is SIX tokens carrying THREE
 * different meanings, which is why this class exists instead of a count of
 * "refusals":
 *
 *   ok                ADMITTED — the machine re-enters the boot path
 *   exec-error        ADMITTED but NOT EXECUTED — the machine is UNCHANGED;
 *                     neither admitted nor refused, and folding it into
 *                     either is a lie in one direction or the other
 *   not-decided       REFUSED, a TIMING (no verdict had landed yet)
 *   boot-failed       REFUSED, a STATE (the verdict landed and it was bad)
 *   shell-open        REFUSED, a human at the console
 *   same-version-loop REFUSED, the writer's own loop bound
 *
 * `not-decided` and `boot-failed` are DELIBERATELY different tokens and are
 * never collapsed here: "did not know yet" and "knew, and the answer was
 * bad" are two states, and a durable record that merges them cannot be read
 * (the S1 review added the sixth token for exactly this).  A token outside
 * the writer's set is surfaced VERBATIM and counted as `unknown`, never
 * silently folded into a bucket: a newer writer's word must not read as
 * coherent here.
 *
 * THE IDENTITY A REBOOT STREAK IS KEYED ON IS THE ROW'S OWN from-version,
 * AND ITS RESET IS THE GENERATION MOVE — the writer's own rule
 * (operator_journal.zig's consecutiveRebootsAt, :599-625): walking the
 * journal, an ADMITTED row at the same from-version extends the streak, a
 * row from a DIFFERENT version or a non-reboot row that MOVED the generation
 * ends it, and a REFUSED row neither extends nor ends it.  Keying it on
 * anything else — the row count, or the version number as the identity
 * instead of the row — changes the reading, which is what the gate's mutants
 * prove. */
typedef enum {
    RBC_ADMITTED, RBC_UNEXECUTED, RBC_REFUSED_TIMING, RBC_REFUSED_STATE,
    RBC_REFUSED_SHELL, RBC_REFUSED_LOOP, RBC_UNKNOWN
} rbclass_t;

static rbclass_t rb_classify(const char *t) {
    if (!strcmp(t, "ok")) return RBC_ADMITTED;
    if (!strcmp(t, "exec-error")) return RBC_UNEXECUTED;
    if (!strcmp(t, "not-decided")) return RBC_REFUSED_TIMING;
    if (!strcmp(t, "boot-failed")) return RBC_REFUSED_STATE;
    if (!strcmp(t, "shell-open")) return RBC_REFUSED_SHELL;
    if (!strcmp(t, "same-version-loop")) return RBC_REFUSED_LOOP;
    return RBC_UNKNOWN;
}

static const char *rb_class_name(rbclass_t c) {
    switch (c) {
    case RBC_ADMITTED: return "admitted";
    case RBC_UNEXECUTED: return "admitted-not-executed";
    case RBC_REFUSED_TIMING: return "refused-timing";
    case RBC_REFUSED_STATE: return "refused-state";
    case RBC_REFUSED_SHELL: return "refused-shell";
    case RBC_REFUSED_LOOP: return "refused-loop";
    default: return "unknown-token";
    }
}

/* REUSED, NOT CHOSEN: the loop bound IS fx-init's REBOOT_SAME_VERSION_MAX
 * (fx-init zig/src/operator_journal.zig:379, value 2 — "at most TWO
 * consecutive admitted reboots whose .operator row carries the SAME
 * from-version; the THIRD is refused, loudly, with its own row").  The
 * admission ACTS on it (consecutiveRebootsAt >= MAX -> same-version-loop,
 * :528) and this seat only REPORTS it, so the two compute the same quantity
 * under the same bound from the same rows, INDEPENDENTLY — a divergence
 * between them is a finding about the seats, not a matter of taste.  THE
 * FINDING'S CONVENTION, stated because it decides the number: the writer
 * refuses the (MAX+1)th, so MAX admitted reboots at one from-version is
 * legitimate and the finding fires only ABOVE it. */
#define REBOOT_SAME_VERSION_MAX 2

#define MAX_REBOOT_VERS (MAX_VERSIONS + 1) /* +1 for the "-" (unnamed) group */
#define MAX_REBOOT_TOKENS 8                /* the six + slack; more is a LOUD die */

#define RBC_N (RBC_UNKNOWN + 1) /* one counter per class, UNKNOWN included */

typedef struct {
    unsigned count;
    unsigned n[RBC_N];       /* by rbclass_t, RBC_UNKNOWN included */
    struct { char tok[64]; unsigned n; } toks[MAX_REBOOT_TOKENS];
    unsigned ntok;
} rbver_t;

typedef struct {
    char from_s[16];
    rbver_t v;
} rbverrow_t;

static rbverrow_t g_rbv[MAX_REBOOT_VERS];
static unsigned g_nrbv;
static unsigned g_nreb;             /* `reboot` rows in the journal */
static unsigned g_rb_max_streak;     /* max consecutive ADMITTED at one from-version */
static char g_rb_max_from[16];
static unsigned g_rb_top_count;      /* the most-rebooted from-version's count */
static char g_rb_top_from[16];
static unsigned g_rb_boots_max;      /* boots-per-content-max */
static const char *g_rb_boots_gh;    /* ... and the identity that carries it */
static int g_rb_boots_known;         /* 0 when no .bootlog line exists at all */

static void build_reboot(void) {
    char streak_from[16] = "-";
    unsigned streak = 0;
    for (unsigned i = 0; i < g_nop; i++) {
        oprow_t *O = &g_op[i];
        if (strcmp(O->action, "reboot")) {
            /* the writer's own streak-reset rule (movedGeneration): a
             * NON-reboot row moves the generation when its to-version is a
             * version and differs from its from-version.  A refused
             * activation has to="-" and moves nothing. */
            if (strcmp(O->to_s, "-") && strcmp(O->to_s, O->from_s)) {
                streak = 0;
                snprintf(streak_from, sizeof streak_from, "%s", "-");
            }
            continue;
        }
        g_nreb++;
        rbclass_t c = rb_classify(O->outcome);
        rbver_t *G = NULL;
        for (unsigned k = 0; k < g_nrbv; k++)
            if (!strcmp(g_rbv[k].from_s, O->from_s)) { G = &g_rbv[k].v; break; }
        if (!G) {
            if (g_nrbv >= MAX_REBOOT_VERS)
                die("more than %u distinct reboot from-versions — raise MAX_REBOOT_VERS "
                    "(a partial measure is a lie)", (unsigned)MAX_REBOOT_VERS);
            G = &g_rbv[g_nrbv].v;
            snprintf(g_rbv[g_nrbv].from_s, sizeof g_rbv[0].from_s, "%s", O->from_s);
            g_nrbv++;
        }
        G->count++;
        G->n[c]++;
        unsigned t = 0;
        for (; t < G->ntok; t++)
            if (!strcmp(G->toks[t].tok, O->outcome)) { G->toks[t].n++; break; }
        if (t == G->ntok) {
            if (G->ntok >= MAX_REBOOT_TOKENS)
                die("more than %u distinct reboot outcome tokens at from-version %s — "
                    "raise MAX_REBOOT_TOKENS (a partial measure is a lie)",
                    (unsigned)MAX_REBOOT_TOKENS, O->from_s);
            snprintf(G->toks[t].tok, sizeof G->toks[t].tok, "%s", O->outcome);
            G->toks[t].n = 1;
            G->ntok++;
        }
        if (G->count > g_rb_top_count) {
            g_rb_top_count = G->count;
            snprintf(g_rb_top_from, sizeof g_rb_top_from, "%s", O->from_s);
        }
        if (c == RBC_ADMITTED) {
            if (!strcmp(streak_from, O->from_s)) streak++;
            else { streak = 1; snprintf(streak_from, sizeof streak_from, "%s", O->from_s); }
            if (streak > g_rb_max_streak) {
                g_rb_max_streak = streak;
                snprintf(g_rb_max_from, sizeof g_rb_max_from, "%s", O->from_s);
            }
        }
    }
    /* BOOTS PER CONTENT: a reboot loop PUBLISHES NOTHING, so it moves no
     * version and no run — the ACTIVITY seat reads it perfectly FLAT.  This
     * is the number that sees it, joined through the identity map above.  No
     * .bootlog at all is NOT-KNOWN, never zero. */
    g_rb_boots_known = (g_bl_present && !g_bl_empty);
    if (g_rb_boots_known) {
        for (unsigned k = 0; k < g_nidents; k++) {
            ident_t *I = &g_idents[k];
            if (!I->known) continue; /* NOT-KNOWN is never a count of anything */
            if (I->boots > g_rb_boots_max) {
                g_rb_boots_max = I->boots;
                g_rb_boots_gh = I->genhash;
            }
        }
    }
}

static void emit_reboot(void) {
    for (unsigned i = 0; i < g_nop; i++) {
        oprow_t *O = &g_op[i];
        if (strcmp(O->action, "reboot")) continue;
        printf("reboot-row\tline\t%u\tepoch\t%u\tfrom-version\t%s\toutcome\t%s\tclass\t%s"
               "\treason\t%s\tnonce\t%s\tMEASURED\n",
               O->lineno, O->epoch, O->from_s, O->outcome,
               rb_class_name(rb_classify(O->outcome)), O->arg, O->nonce);
    }
    for (unsigned k = 0; k < g_nrbv; k++) {
        rbver_t *G = &g_rbv[k].v;
        printf("reboot-version\t%s\treboots\t%u\tadmitted\t%u\trefused\t%u\tunexecuted\t%u"
               "\tunknown\t%u\ttokens\t", g_rbv[k].from_s, G->count, G->n[RBC_ADMITTED],
               G->n[RBC_REFUSED_TIMING] + G->n[RBC_REFUSED_STATE] + G->n[RBC_REFUSED_SHELL]
                   + G->n[RBC_REFUSED_LOOP],
               G->n[RBC_UNEXECUTED], G->n[RBC_UNKNOWN]);
        for (unsigned t = 0; t < G->ntok; t++)
            printf("%s%s:%u", t ? "," : "", G->toks[t].tok, G->toks[t].n);
        printf("\tMEASURED\n");
    }
    /* THE TWO ABSENCES THIS CLASS CAN HAVE, each its OWN state and each
     * stated so it cannot be read as "none". */
    if (!g_op_present)
        printf("reboot-absence\t.operator\tnot-known-no-operator-journal-never-no-reboots\tABSENT\t"
               "a store whose .operator is not there CANNOT answer how many reboots there were "
               "(it predates the journal, or never booted under it) — ZERO IS NOT THE ANSWER, "
               "and absence/.operator above is the same state\n");
    if (!g_rb_boots_known)
        printf("reboot-absence\t.bootlog\tboots-per-content-not-known-%s\tABSENT\t"
               "with no boot line there is no count of boots per content: 0 WOULD BE A CLAIM "
               "THAT NOTHING BOOTED, and the record cannot say that\n",
               g_bl_present ? "bootlog-present-but-empty" : "no-bootlog");
    if (g_rb_max_streak > REBOOT_SAME_VERSION_MAX)
        printf("reboot-finding\tconsecutive-same-version\tfrom-version\t%s\tstreak\t%u"
               "\tbound\tREBOOT_SAME_VERSION_MAX=%u\tat\tfx-init zig/src/operator_journal.zig:379"
               "\tMEASURED\t"
               "the record holds %u CONSECUTIVE ADMITTED reboot(s) at v%s with no generation "
               "move between them, while fx-init's REBOOT_SAME_VERSION_MAX=%u "
               "(zig/src/operator_journal.zig:379, consecutiveRebootsAt :599-625) refuses the "
               "(MAX+1)th request at one from-version by NAME (same-version-loop) — so either "
               "an fx-init WITHOUT the admission wrote these rows, or something wrote them "
               "AROUND it.  A reboot moves NO generation, so the ACTIVITY seat reads this same "
               "stretch of history FLAT.  This seat reports it and stops nothing "
               "(bound/reboot-is-not-a-policy)\n",
               g_rb_max_from, g_rb_max_streak, (unsigned)REBOOT_SAME_VERSION_MAX,
               g_rb_max_streak, g_rb_max_from, (unsigned)REBOOT_SAME_VERSION_MAX);
    if (g_rb_max_streak > REBOOT_SAME_VERSION_MAX) g_findings++;
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
        else if (!strcmp(argv[i], "--proxy-log") && i + 1 < argc) g_proxy_log = argv[++i];
        else if (!strncmp(argv[i], "--proxy-log=", 12)) g_proxy_log = argv[i] + 12;
        else if (!strcmp(argv[i], "--transcript") && i + 1 < argc) g_transcript = argv[++i];
        else if (!strncmp(argv[i], "--transcript=", 13)) g_transcript = argv[i] + 13;
        else if (!strcmp(argv[i], "--policy-dir") && i + 1 < argc) g_policy_dir = argv[++i];
        else if (!strncmp(argv[i], "--policy-dir=", 13)) g_policy_dir = argv[i] + 13;
        else if (!strcmp(argv[i], "--class-arg") && i + 1 < argc) add_classarg(argv[++i]);
        else if (!strncmp(argv[i], "--class-arg=", 12)) add_classarg(argv[i] + 12);
        else if (!strcmp(argv[i], "--proxy") && i + 1 < argc) g_proxy = argv[++i];
        else if (!strncmp(argv[i], "--proxy=", 8)) g_proxy = argv[i] + 8;
        else if (!strcmp(argv[i], "--help")) {
            printf("usage: fx-report [--store DIR] [--fxstore BIN] [--max-config-lines N]"
                   " [--proxy-log FILE] [--transcript FILE]\n"
                   "                  [--policy-dir DIR] [--class-arg DIM:TOOL=KEY]..."
                   " [--proxy BIN]\n"
                   "  --policy-dir DIR   the operator's PINNED class tables (ops-aliases.tsv,\n"
                   "                     ops-hosts.tsv, ops-sandbox.tsv) + PINS: the DECLARED\n"
                   "                     side of the reach AND sandbox classes\n"
                   "  --class-arg D:TOOL=KEY  declare that TOOL's classed argument is KEY in\n"
                   "                     dimension D (path|authority) — the registry's arg_key\n"
                   "                     is C and this seat will not respell it; an undeclared\n"
                   "                     dimension reads NOT-KNOWN, never 'no classed argument'\n"
                   "  --proxy BIN        the host proxy whose OWN --print-sandbox is the\n"
                   "                     composed sandbox declaration (the executor baseline +\n"
                   "                     each tool's sidecar); a proxy that cannot be run is a\n"
                   "                     TOOL ERROR (exit 2), never 'no sandbox'\n");
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
    read_proxy_log();
    read_transcript();
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
    /* the content-identity table the progress class and its summary read
     * (built once: ACTIVITY by CONTENT, never by the version number) */
    build_identities(cur_v);
    /* the REBOOT class's numbers: its rows are the journal's `reboot` rows,
     * and its boots-per-content join needs the identity table above. */
    build_reboot();
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
     * init.zig:983), so a file that is not there is a store that never
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

    /* progress: the COLLAPSE of those per-version classifications into one
     * row per CONTENT IDENTITY, plus the per-version verdict join.  Placed
     * here so it reads as what it is — the same chain, counted by content
     * instead of by version number. */
    emit_progress();

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

    /* THE REBOOT CLASS (S4): the `reboot` rows of the SAME durable journal,
     * classified by the writer's six-token vocabulary — see the class's own
     * comment above build_reboot.  A reboot refusal is NOT an activation
     * refusal (it matches no token of outcome_is_refusal above), so it is
     * recorded here and nowhere else. */
    emit_reboot();

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

    /* ── THE CALL CLASS (P9): the host proxy's ONE LOG, the guest's
     * transcript, and the join between them by call_id.  MEASURED, and
     * emitted only when a side was named (the class is unarmed otherwise —
     * unlike the claim class, the log and the transcript live at paths the
     * caller names, so there is no store-sibling default to read). ──────── */
    emit_calls();

    /* ── THE REACH CLASS (S4): the WEAKENED declared-vs-observed audit —
     * the operator's pinned class tables + PINS against the one log's own
     * rows.  Two findings, each its own row and meaning: stale-class-row (a
     * stale grant) and pin-drift (the table judged against is not the table
     * pinned).  Armed only when a side is named (the call class's rule). ── */
    emit_reach();

    /* ── THE SANDBOX CLASS (S4, palisade): a spec IS a capability
     * declaration, so the composed spec per tool (the proxy's own
     * --print-sandbox) is compared against the spec the log RECORDED each
     * host call applying, with the operator artifact's pin as the one
     * pinned half.  A widening is a FINDING; the mirror direction is named
     * and not judged.  Two directions of absence, once per side. ──────── */
    emit_sandbox();

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

    /* ── ACTIVITY / PROGRESS: the headline is a READING, not a record, so it
     *    prints in the `#` summary BESIDE the records, never instead of them.
     *    Every line of both blocks is prefixed ACTIVITY or PROGRESS, which is
     *    also what lets the gate's pre-fix pin drop them by one rule — and
     *    what stops a reader mistaking a count for its source. ─────────── */
    {
        unsigned n_known = 0, n_benign = 0, n_ident = 0;
        unsigned v_ok = 0, v_fa = 0, v_ip = 0, v_nj = 0, v_ot = 0;
        for (unsigned k = 0; k < g_nidents; k++) {
            ident_t *I = &g_idents[k];
            v_ok += I->ok; v_fa += I->failed; v_ip += I->inprog;
            v_nj += I->notjudged; v_ot += I->other;
            if (!I->known) continue;
            n_ident++;
            n_known += I->versions;
            n_benign += I->benign_repeats;
        }
        unsigned n_activity = n_known - n_benign; /* content-advancing publishes */
        unsigned n_progress = n_ident;            /* the first sightings */
        h("ACTIVITY (by CONTENT IDENTITY, never by the version number) — %u published "
          "version(s) = %u with `generation` facts + %u NOT-KNOWN (no facts as of that "
          "version: counted in NEITHER activity nor progress).", g_nvers, n_act, n_gh);
        h("ACTIVITY = %u content-advancing publish(es) = %u first-sighting(s) + %u repeat(s) of "
          "a known identity; the publish protocol's own pair contributes %u version(s) and is "
          "NOT activity (MEASURED: every fx-activate run after the first leaves a BENIGN PAIR — "
          "a duplicate of the previous generation, then the new one: fx-report.c:3104-3107).",
          n_activity, n_progress, n_activity - n_progress, n_benign);
        h("ACTIVITY blind to WHAT the content does: whether it WORKS or was USEFUL, and whether "
          "it was INTENDED — a long USEFUL task that publishes nothing looks perfectly FLAT "
          "here (this counts COMMITS, not work) and a repeat may be a legitimate re-application "
          "of the same config after an unrelated repair "
          "(bound/activity-without-progress-cannot-see-intent).  Also blind BY CONSTRUCTION to "
          "activity that left NO store record — a task re-run that published nothing, which "
          "only the harness's attempts.jsonl holds and this seat is FORBIDDEN to read "
          "(bound/progress-blind-to-the-self-report).");
        h("PROGRESS (a FIRST SIGHTING of a content identity) — %u distinct identit%s, %u "
          "first-sighting(s), %u repeat(s), and a repeat is ZERO progress by definition (same "
          "content, new number).  progress/activity = %u/%u, the denominator being the "
          "content-advancing count so the publish pair does not deflate it: a READING, never a "
          "grade — this seat does not say the new content is BETTER (that is `osier-share`, "
          "§7.1).", n_progress, n_progress == 1 ? "y" : "ies", n_progress,
          n_activity - n_progress, n_progress, n_activity);
        if (!g_bl_present || g_bl_empty)
            h("PROGRESS verdicts: NOT-KNOWN — %s, so EVERY version reads not-judged and "
              "`failed` is 0 because NOTHING WAS JUDGED, never because nothing failed (an "
              "absent log must not become a zero).",
              g_bl_present ? "the log is present but empty" : "no .bootlog exists");
        else
            h("PROGRESS verdict join: the LAST non-`shutdown` .bootlog status per version, in "
              "FILE ORDER (an in-progress later RESOLVED to ok reads ok; an UNRESOLVED "
              "in-progress tail counts as failed — the same evidence the recovery trigger "
              "reads as stale; fx-init init.zig:1115-1127, bootver_apply) — %u ok, %u failed, %u in-progress, "
              "%u not-judged, %u status word(s) outside the writer's set.", v_ok, v_fa, v_ip,
              v_nj, v_ot);
        h("PROGRESS cannot see the OTHER loop shape: ALWAYS-NEW content, always failing — every "
          "identity fails exactly once, no count ever reaches the recurrence threshold, and "
          "this seat would report FULL PROGRESS over a wall of failures (the boot guardrail "
          "misses it too: its fail_n is per-genhash).  It prints as two NUMBERS and is "
          "deliberately NOT a finding (an honest debugging session looks identical): "
          "identities-never-ok %u (zero ok verdicts among their NON-CURRENT versions — CURRENT "
          "is EXCLUDED, because a boot verdict arrives one boot LATER than the state it "
          "judges) and longest-failed-streak %u (consecutive content-advancing publishes "
          "judged failed/in-progress).  The recurrence finding does NOT cover that shape "
          "(bound/progress-cannot-see-a-changing-content-loop).",
          identities_never_ok(), longest_failed_streak());
    }

    /* ── REBOOT: THE IN-GUEST REBOOT, READ FROM ITS OWN ROWS ──────────────
     *    The plan's S4 and todo.md §4's last slice.  Every line is prefixed
     *    REBOOT, so the gate's PIN-REPORT filter drops the block by one
     *    regex — the discipline the activity seat established, and the
     *    reason a reading never masquerades as a record. ───────────────── */
    {
        unsigned n_adm = 0, n_une = 0, n_unk = 0;
        unsigned n_timing = 0, n_state = 0, n_shell = 0, n_loop = 0;
        for (unsigned k = 0; k < g_nrbv; k++) {
            rbver_t *G = &g_rbv[k].v;
            n_adm += G->n[RBC_ADMITTED];     n_une += G->n[RBC_UNEXECUTED];
            n_timing += G->n[RBC_REFUSED_TIMING]; n_state += G->n[RBC_REFUSED_STATE];
            n_shell += G->n[RBC_REFUSED_SHELL];   n_loop += G->n[RBC_REFUSED_LOOP];
            n_unk += G->n[RBC_UNKNOWN];
        }
        unsigned n_ref = n_timing + n_state + n_shell + n_loop;
        if (!g_op_present) {
            h("REBOOT: NOT-KNOWN — no .operator journal exists for this store, so this class "
              "cannot say how many reboots there were.  ZERO IS NOT THE ANSWER: a store that "
              "predates the journal (or never booted under it) has no record of a reboot, and "
              "'no reboots' is a claim about the machine that nothing here supports "
              "(bound/reboot-is-not-a-policy).");
        } else {
            h("REBOOT (from the .operator `reboot` rows, fx-init bb0642f) — %u row(s): %u "
              "ADMITTED (ok — the machine re-entered the boot path), %u REFUSED, %u "
              "ADMITTED-BUT-NOT-EXECUTED (exec-error — the machine is UNCHANGED: neither an "
              "admission nor a refusal, and folding it into either is a lie), %u token(s) "
              "outside the writer's six-token vocabulary (surfaced VERBATIM above, never "
              "silently classified).", g_nreb, n_adm, n_ref, n_une, n_unk);
            h("REBOOT refusals BY TOKEN, each its OWN state and NEVER collapsed: not-decided "
              "%u (a TIMING — no verdict had landed, the grace window was open), boot-failed %u "
              "(a STATE — the verdict LANDED and it was failed), shell-open %u (a human at the "
              "console), same-version-loop %u (the writer's own loop bound).  The two "
              "look-alikes are deliberately different tokens: \"did not know yet\" and \"knew, "
              "and the answer was bad\" are different states, and a record that merges them "
              "cannot be read (fx-init operator_journal.zig:165-215).%s",
              n_timing, n_state, n_shell, n_loop,
              g_nreb ? "" : "  NO reboot row is recorded in the journal — a MEASUREMENT of the "
                            "journal, never 'the machine never rebooted': an fx-init without "
                            "the verb cannot write a row at all.");
            h("REBOOT at versions — %u distinct from-version(s); the most-rebooted is %s with "
              "%u row(s).  A from-version of \"-\" is the journal's UNKNOWN and is its own "
              "group, never v0.", g_nrbv, g_nrbv ? g_rb_top_from : "-", g_rb_top_count);
            h("REBOOT loop bound: consecutive-same-version-max %u (at v%s) against "
              "REBOOT_SAME_VERSION_MAX=%u (fx-init zig/src/operator_journal.zig:379, "
              "consecutiveRebootsAt :599-625, reused not chosen): the writer REFUSES the "
              "(MAX+1)th admitted reboot at one from-version, so at most %u is legitimate and "
              "MORE is the state the admission makes unreachable — a finding.%s",
              g_rb_max_streak, g_rb_max_streak ? g_rb_max_from : "-",
              (unsigned)REBOOT_SAME_VERSION_MAX, (unsigned)REBOOT_SAME_VERSION_MAX,
              g_rb_max_streak > REBOOT_SAME_VERSION_MAX ? "  THIS RECORD EXCEEDS IT." : "");
            if (!g_rb_boots_known)
                h("REBOOT boots-per-content: NOT-KNOWN — %s, so the number of boots that "
                  "STARTED at a content is not countable here (0 would be a claim that nothing "
                  "booted; bound/reboot-is-not-a-policy).",
                  g_bl_present ? "the .bootlog is present but empty" : "no .bootlog exists");
            else {
                char bnote[160];
                if (g_rb_boots_gh)
                    snprintf(bnote, sizeof bnote, " (the content %s)", g_rb_boots_gh);
                else
                    snprintf(bnote, sizeof bnote, "%s", "");
                h("REBOOT boots-per-content-max %u%s.  READ IT WITH ACTIVITY, WHICH IS THE "
                  "WHOLE POINT: a reboot loop PUBLISHES NOTHING — it moves no version and no "
                  "run — so the ACTIVITY seat reads it perfectly FLAT (1 version / 1 run / 0 "
                  "repeats).  High activity with a high boots-per-content is the OSCILLATOR; "
                  "high activity with a low one is a healthy loop.  The always-new-content loop "
                  "is PRINTED as these numbers and deliberately NOT a finding (an honest "
                  "debugging session looks identical; bounding it is the ORACLE's job).",
                  g_rb_boots_max, bnote);
            }
            h("REBOOT blind spots, where the number is read: the row records the ADMISSION, "
              "never the EXECUTION (an admitted reboot that never executed reads as the "
              "ABSENCE of a later .bootlog line under that nonce) — and `exec-error` is "
              "therefore DEFINED BUT UNPRODUCED by the current writer (fx-init bb0642f writes "
              "the one row before the exec), so its count of %u is the vocabulary's, not a "
              "measurement of failed re-entries; a reboot being VISIBLE is "
              "not the reboot being STRONG — it is a USERSPACE RE-ENTRY under the same kernel "
              "boot, with no firmware, no device re-init and no kernel restart, so a device "
              "that wedged stays wedged (bound/reboot-visible-is-not-strong); and this seat "
              "GATES, REFUSES AND STOPS NOTHING (bound/reboot-is-not-a-policy).", n_une);
        }
    }
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
    if (g_proxy_log || g_transcript) {
        h("call records: the host log <-> guest transcript join by call_id — %u judged call(s) "
          "(%u denied, %u allowed, %u with NO verdict recorded; %u HOST-executed, %u "
          "guest-executed — the exec dimension is what makes an egress grant visible), "
          "%u joined to the transcript, "
          "%u host-log-only and %u transcript-only (%s), %u disagreement(s) (the record of the "
          "gate working, VERBATIM — not a reporter verdict), %u telemetry row(s) (records, NOT "
          "triggers: no lane stop by default).",
          g_nhcalls, g_c_denied, g_c_allowed, g_c_nov, g_c_hostexec, g_c_guesexec,
          g_c_joined, g_c_hostonly, g_c_tranonly,
          (g_c_hostonly || g_c_tranonly) ? "each its own FINDING" : "the join fired in both directions",
          g_c_disagree, g_c_tele);
        if (!g_proxy_log || !g_transcript)
            h("  (one side of the join was NOT given — its silence is NOT-KNOWN, named in the "
              "absence records above, never read as 'no call'.)");
    }
    if (g_policy_dir || g_proxy_log) {
        unsigned n_stale = 0, n_unk = 0, n_hit = 0, n_drift = 0;
        for (unsigned i = 0; i < g_nrrows; i++) {
            int aliases = !strcmp(g_rrows[i].table, "ops-aliases.tsv");
            int known = 0;
            int hit = reach_row_exercised(&g_rrows[i], aliases, &known);
            if (hit) n_hit++; else if (known) n_stale++; else n_unk++;
        }
        for (unsigned i = 0; i < g_npins; i++)
            if (!g_pins[i].present || strcmp(g_pins[i].got, g_pins[i].want) != 0) n_drift++;
        h("reach (the WEAKENED declared-vs-observed audit, named as such): %u pinned class "
          "row(s) — %u exercised by an observed call, %u STALE (no observed call consumed "
          "them: a revocation question, each its own FINDING), %u NOT-KNOWN (no observed "
          "side or no --class-arg mapping for their dimension — never read as stale); "
          "%u artifact(s) drifted from PINS (each its own FINDING with both pins); %u "
          "declared --class-arg mapping(s).", g_nrrows, n_hit, n_stale, n_unk, n_drift,
          g_nclassargs);
        if (!g_policy_dir)
            h("  the DECLARED side was NOT given (no --policy-dir): the reach class cannot "
              "say what is granted, and that is NOT-KNOWN — never 'nothing is granted'.");
        if (!g_proxy_log)
            h("  the OBSERVED side was NOT given (no --proxy-log): no class row can be "
              "attributed, so every row reads NOT-KNOWN — NEVER stale, and never 'nothing "
              "was called'.");
        h("  this is NOT the type-enforced audit: egress is judged ARGUMENTS, not a type, so "
          "there is no per-generation declaration for observed traffic to violate (bound/"
          "reach-audit-is-the-weakened-one).  What it can see — and what §7.1a demands an "
          "oracle see — is a grant that is WIDER than the traffic, and a table that is not "
          "the table the release pinned.");
    }
    if (g_proxy || g_proxy_log || g_policy_dir) {
        unsigned n_composed = g_nsbt, n_recorded = g_nsbo;
        h("sandbox (a spec IS a capability declaration, named as the WEAKENED audit it is): "
          "%u tool composition(s) DECLARED now, %u distinct applied spec(s) RECORDED in the "
          "log, %u host call(s) whose spec is NOT-KNOWN (a pre-S3 row) — "
          "bound/sandbox-audit-is-the-weakened-one and bound/sandbox-visible-is-not-strong "
          "are the two halves of what this cannot say.", n_composed, n_recorded, g_c_sbunk);
        if (!g_proxy)
            h("  the DECLARED composition was NOT given (no --proxy): the sandbox cannot be "
              "compared and is NOT-KNOWN — never 'unchanged'.");
        if (!g_proxy_log)
            h("  the RECORDED specs were NOT given (no --proxy-log): what each host call "
              "applied is NOT-KNOWN — never 'nothing ran widened'.");
        if (!g_policy_dir)
            h("  the OPERATOR table's pin was NOT given (no --policy-dir): whether the "
              "tightening table is the released one is NOT-KNOWN — never 'no edit'.");
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
