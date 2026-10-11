#ifndef RUNSTORE_H
#define RUNSTORE_H

/* src/runstore.h — DAFSA-backed RunStore.
 *
 * A RunStore on the user's datalog-dafsa fact store.  All mutable per-run state is represented as fixed-width u32 facts;
 * strings are interned to 1-based sym_ids (0 = null sentinel).  See the design
 * record (docs/baliveau-self-plan.md) for the full durability/schema
 * rationale.
 *
 * The single load-bearing rule, baked into every mutator:
 *   ADD the new fact FIRST, then DELETE the old.  A crash between them
 *   leaves a duplicate (at-least-once-safe), self-healed on the next
 *   transition (collapse n>1 to 1).  Idempotency checks ALL matching rows.
 *   NEVER call dl_add_fact/dl_delete_fact/dl_intern_str inside a
 *   dl_prefix callback (DAFSA walker UAF); collect-then-mutate.
 */

#include <stddef.h>
#include <stdint.h>
#include <pthread.h>
#include "vendor/datalog-dafsa/src/dl.h"

/* ── Relation names (must match dl_declare_relation exactly) ──────────── */
#define RS_REL_RUN   "run"     /* arity 1: (run_id)               presence/identity */
#define RS_REL_ATTR  "attr"    /* arity 4: (run_id, attr, seq, value)  scalar fields  */
#define RS_REL_INSTR "instr"   /* arity 3: (run_id, chunk_idx, chunk_sym) instructions */
#define RS_REL_AMEND "amend"   /* arity 5: (run_id, seq, ts, text, applied) amends list */

/* ── Sentinels ────────────────────────────────────────────────────────── */
#define RS_SYM_NULL  0u           /* absent string field (interner is 1-based) */
#define RS_INT_NULL  0xFFFFFFFFu  /* reserved; null INT fields use row ABSENCE
                                     instead (any u32 could be a legit
                                     two's-complement int, e.g. exit_code -1) */

/* Max internable string = 4091 bytes (MAX_WORD_LEN=4096, interner key = slen+5).
 * Chunk instructions (and reject amend text) at/below this. */
#define RS_INTERN_MAX  4091u

/* ── Run statuses (port of jobs.py STATUS_*) ──────────────────────────── */
#define RS_STATUS_QUEUED   "queued"
#define RS_STATUS_RUNNING  "running"
#define RS_STATUS_PAUSED   "paused"
#define RS_STATUS_DONE     "done"
#define RS_STATUS_FAILED   "failed"
#define RS_STATUS_CANCELLED "cancelled"
#define RS_STATUS_ORPHANED "orphaned"

/* ── Attribute metadata (the EAV value-type table) ─────────────────────── */
typedef enum {
    RS_ATTR_AGENT = 0,
    RS_ATTR_SLUG,
    RS_ATTR_CWD,
    RS_ATTR_SESSION_ID,
    RS_ATTR_MAX_TURNS,
    RS_ATTR_SECRETS_SCOPE,
    RS_ATTR_SCHEDULE_ID,
    RS_ATTR_STATUS,
    RS_ATTR_EXIT_CODE,
    RS_ATTR_PID,
    RS_ATTR_PAUSED_AT,
    RS_ATTR_LAST_TURN_AT,
    RS_ATTR_CREATED_AT,
    RS_ATTR_COUNT
} rs_attr_id;

typedef struct {
    const char *name;    /* the interned attr key, e.g. "status" */
    int         is_int;  /* 1 => value is a raw u32 two's-complement int;
                            0 => value is an interned sym_id */
    int         mutable_;/* 1 => seq-versioned (set_attr increments seq);
                            0 => immutable (seq 0, set once at add) */
} rs_attr_meta;

/* Implemented in runstore.c as a single const table. */
extern const rs_attr_meta RS_ATTR_META[RS_ATTR_COUNT];

/* ── The reconstructed run record (caller-owned strings) ──────────────── */
typedef struct rs_amend {
    char *ts;       /* interned-then-resolved ISO timestamp */
    char *text;     /* amend text */
    int   applied;  /* 0 or 1 */
} rs_amend;

typedef struct AgentRun {
    char  *run_id;
    char  *agent;
    char  *slug;
    char  *instructions;   /* reassembled from `instr` chunks */
    char  *cwd;
    char  *session_id;     /* "" when not yet discovered */
    int    max_turns;
    char  *secrets_scope;
    char  *schedule_id;    /* "" for ad-hoc */
    char  *status;
    char  *created_at;
    char  *paused_at;      /* NULL when absent */
    char  *last_turn_at;   /* NULL when absent */
    int    has_exit_code;  /* 0 => exit_code was null */
    int    exit_code;
    int    has_pid;        /* 0 => pid was null */
    int    pid;
    rs_amend *amends;
    size_t n_amends;
} AgentRun;

void agentrun_free(AgentRun *r);

/* Free an array of AgentRun* returned by runstore_list (frees each run too). */
void runstore_list_free(AgentRun **runs, size_t n);

/* Free an rs_amend array returned by runstore_snapshot_amends. */
void runstore_amends_free(rs_amend *a, size_t n);

/* ── Store handle ─────────────────────────────────────────────────────── */
typedef struct RunStore {
    dl_db         *db;     /* dl_open2 handle; single-writer fcntl LOCK held */
    pthread_mutex_t lock;  /* in-process serialization (== RunStore._lock) */
    char          *dir;    /* db directory (owned) */
    uint32_t       attr_syms[RS_ATTR_COUNT]; /* interned attr-name sym_ids */
    int            max_runs;          /* FX_MAX_RUNS (default 50) */
    int            max_instr_chars;   /* FX_MAX_INSTRUCTIONS_CHARS (default 32768) */
} RunStore;

/* ── Public API (mirrors jobs.py RunStore) ────────────────────────────── */
/* Return 0 on success, non-zero on error; fill err[errcap] (may be NULL).
 * The caller allocates the RunStore (stack or heap) and zeroes nothing —
 * runstore_open initializes it.  FAILS OPEN: a store whose base DAFSA /
 * interner fails to load opens EMPTY (matches jobs.py corrupt-file policy).
 *
 * NOT async-signal-safe: never call these from a signal handler (the
 * engine holds no internal mutex; the SIGCHLD reaper must defer to the
 * main loop, exactly like daemon.py's WNOHANG sweep). */
int  runstore_open(RunStore *rs, const char *dir, char *err, size_t errcap);
void runstore_close(RunStore *rs);

/* runstore_add: ports RunStore.add.  The store applies the AgentRun
 * dataclass defaults (status "queued", session_id "", secrets_scope
 * "minimal", schedule_id "", created_at now-if-empty, max_turns 30 if <=0)
 * exactly like Python __init__/__post_init__.  Rejections (RunError):
 * duplicate run_id ("already exists"), MAX_RUNS ("maximum runs ... reached"),
 * instructions longer than max_instr_chars ("instructions too long ..."),
 * run_id / any required string not internable within RS_INTERN_MAX. */
int  runstore_add(RunStore *rs, const AgentRun *run, char *err, size_t errcap);

/* NULL if absent (or the stored item fails validation — the "ignores bad
 * items" policy); caller frees via agentrun_free. */
AgentRun *runstore_get(RunStore *rs, const char *run_id);

/* Caller frees via runstore_list_free.  Bad items are skipped. */
int  runstore_list(RunStore *rs, AgentRun ***out, size_t *out_n);

/* 0 removed, -1 absent/err. */
int  runstore_remove(RunStore *rs, const char *run_id);

/* Setters: 0 on success, -1 if the run is absent (RunError "not found") or
 * the value is invalid/too long to intern.  set_paused_at(NULL) clears. */
int  runstore_set_status(RunStore *rs, const char *run_id, const char *status);
int  runstore_set_session_id(RunStore *rs, const char *run_id, const char *sid);
int  runstore_set_exit_code(RunStore *rs, const char *run_id, int code);
int  runstore_set_pid(RunStore *rs, const char *run_id, int pid);
int  runstore_set_paused_at(RunStore *rs, const char *run_id, const char *iso); /* NULL clears */
int  runstore_set_last_turn_at(RunStore *rs, const char *run_id, const char *iso);

/* Amends: append stamps ts=now; text longer than RS_INTERN_MAX is rejected.
 * mark_amend_applied flips every unapplied amend (no-op if none).
 * snapshot_amends returns a FRESH deep copy under the lock (caller frees
 * via runstore_amends_free).  All return 0/-1. */
int  runstore_append_amend(RunStore *rs, const char *run_id, const char *text);
int  runstore_mark_amend_applied(RunStore *rs, const char *run_id);
int  runstore_snapshot_amends(RunStore *rs, const char *run_id,
                              rs_amend **out, size_t *out_n);

/* Audit log: JSONL sidecar (NOT datalog-dafsa), best-effort append —
 * byte-compatible with jobs.py audit_append ({"ts", "action", "run_id",
 * "detail"} with Python json.dumps separators).  Always 0; I/O errors are
 * absorbed exactly like the Python try/except OSError. */
int  runstore_audit_append(const char *audit_path, const char *action,
                           const char *run_id, const char *detail);

/* ── Internal helpers (defined in runstore.c; documented here as the
 *    algorithm the implementer MUST follow — not public API) ──────────── */

/* get_attr: dl_prefix(RS_REL_ATTR, [run_sym, attr_sym], k=2, collect_cb);
 *   pick the row with max seq; return its value (sym or raw u32 per meta).
 *   NO mutation inside the callback. */

/* set_attr(R, attr, new_val):
 *   1. collect ALL (R,attr,*,*) rows via dl_prefix(k=2) into a buffer;
 *   2. intern new_val if is_int==0 (BEFORE the walk's mutation phase);
 *   3. new_seq = max(seen seq)+1 (0 if none);
 *   4. dl_add_fact(attr, [R,attr,new_seq,new_val])  // ADD FIRST
 *   5. for each collected row with seq<new_seq: dl_delete_fact.  // DELETE after
 *   A crash between 4 and 5 leaves {old,new}; next set_attr collapses to max seq. */

#endif /* RUNSTORE_H */
