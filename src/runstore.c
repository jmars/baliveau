/* src/runstore.c — DAFSA-backed RunStore (Slice 2).
 *
 * Port of vibe_runtime/jobs.py RunStore onto the datalog-dafsa fact store —
 * the fx stack's OWN Zig engine (sibling ../datalog-dafsa), linked as
 * libdatalog.  The legacy C copy this tree used to vendor was removed in the
 * engine swap; runstore.h's "vendor/datalog-dafsa/src/dl.h" include is resolved
 * to the sibling's src/ by the Makefile's build/include shim.  Four fixed-arity
 * relations over one
 * shared interner:
 *
 *   run(run_id)                              arity 1 — presence/identity
 *   attr(run_id, attr, seq, value)           arity 4 — EAV for all scalars
 *   instr(run_id, chunk_idx, chunk_sym)      arity 3 — chunked instructions
 *   amend(run_id, seq, ts, text, applied)    arity 5 — append-only amends
 *
 * Durability rules baked into every mutator (see the Slice-2 plan):
 *   - ADD the new fact FIRST, then DELETE the old; a crash between them
 *     leaves a duplicate that the next transition self-heals (attr reads
 *     take the max-seq row; an amend seq counts as applied iff any row for
 *     it has applied=1).
 *   - COMMIT-POINT ordering: add_run writes attr/instr/amend facts first and
 *     the `run` presence fact LAST (a crash mid-add leaves no phantom run);
 *     remove_run deletes the presence fact FIRST and then sweeps the rest
 *     (a crash mid-sweep leaves only inert orphans keyed by an absent run).
 *   - COLLECT-THEN-MUTATE: never call dl_add_fact / dl_delete_fact /
 *     dl_intern_str inside a dl_prefix callback — the DAFSA walker indexes
 *     d->states[] raw and dafsa_state.c reallocs on growth (walker UAF).
 *   - Single writer: dl_open2 holds a cross-process fcntl LOCK (a second
 *     opener gets DL_E_LOCKED); in-process, every public op is serialized by
 *     rs->lock (the engine has NO internal mutex).  The daemon opens the
 *     store ONCE and holds it for its lifetime.
 *
 * Fail-open policy (matches jobs.py): a store whose base DAFSA fails to load
 * (bad magic / truncated) starts EMPTY, the WAL tail auto-repairs, and facts
 * whose symbols fail to resolve make their run a "bad item" that get()/list()
 * skip rather than return wrong data.
 *
 * The C string API is NUL-terminated by construction, so embedded NUL bytes
 * in instructions / amend text cannot be expressed (the strlen-based
 * interner would otherwise truncate them — rejected by representation).
 */
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L /* getline/strndup/fsync in the engine */
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>
#include <unistd.h>
#include <time.h>

#include "runstore.h"

/* ── Small helpers ────────────────────────────────────────────────────── */

#define RS_ERR(err, errcap, ...)                                            \
    do {                                                                    \
        if (err && errcap > 0)                                              \
            snprintf(err, errcap, __VA_ARGS__);                             \
    } while (0)

/* ISO-8601 UTC "now" in Python datetime.isoformat() shape:
 * "2026-08-17T10:03:40.123456+00:00". */
static void rs_utcnow_iso(char *out, size_t cap) {
    struct timespec ts;
    struct tm tm;
    if (!out || cap < 40) return;
    if (clock_gettime(CLOCK_REALTIME, &ts) != 0) {
        out[0] = '\0';
        return;
    }
    gmtime_r(&ts.tv_sec, &tm);
    size_t n = strftime(out, cap, "%Y-%m-%dT%H:%M:%S", &tm);
    if (n == 0) { out[0] = '\0'; return; }
    snprintf(out + n, cap - n, ".%06ld+00:00", (long)(ts.tv_nsec / 1000));
}

/* Env int with default (invalid / out-of-range falls back, like
 * runner_max_turns).  Python int(env) semantics for VALID numeric values. */
static int rs_env_int(const char *name, int def, int min) {
    const char *s = getenv(name);
    if (!s || !*s) return def;
    char *end = NULL;
    long v = strtol(s, &end, 10);
    if (end == s || *end != '\0' || v < min || v > 1000000000L) return def;
    return (int)v;
}

/* TEST-ONLY crash injection: if the env var is set, die IMMEDIATELY at the
 * named point (no dl_close, no flush — the WAL record before this point is
 * already fsync'd).  This emulates `kill -9` between the ADD and the DELETE
 * so tests can prove the self-heal.  The daemon never sets these. */
static void rs_test_crash(const char *env) {
    const char *v = getenv(env);
    if (v && *v) _exit(9);
}

/* strdup(NULL) -> NULL */
static char *rs_strdup(const char *s) {
    if (!s) return NULL;
    size_t n = strlen(s) + 1;
    char *p = malloc(n);
    if (p) memcpy(p, s, n);
    return p;
}

/* ── Attribute metadata (the EAV value-type table) ─────────────────────── */

const rs_attr_meta RS_ATTR_META[RS_ATTR_COUNT] = {
    /*  name              is_int  mutable */
    [RS_ATTR_AGENT]         = { "agent",         0, 0 },
    [RS_ATTR_SLUG]          = { "slug",          0, 0 },
    [RS_ATTR_CWD]           = { "cwd",           0, 0 },
    [RS_ATTR_SESSION_ID]    = { "session_id",    0, 1 },
    [RS_ATTR_MAX_TURNS]     = { "max_turns",     1, 0 },
    [RS_ATTR_SECRETS_SCOPE] = { "secrets_scope", 0, 0 },
    [RS_ATTR_SCHEDULE_ID]   = { "schedule_id",   0, 0 },
    [RS_ATTR_STATUS]        = { "status",        0, 1 },
    [RS_ATTR_EXIT_CODE]     = { "exit_code",     1, 1 },
    [RS_ATTR_PID]           = { "pid",           1, 1 },
    [RS_ATTR_PAUSED_AT]     = { "paused_at",     0, 1 },
    [RS_ATTR_LAST_TURN_AT]  = { "last_turn_at",  0, 1 },
    [RS_ATTR_CREATED_AT]    = { "created_at",    0, 0 },
};

/* attr sym -> attr id (linear over 13 entries; called per scanned row). */
static int rs_attr_id_of(const RunStore *rs, uint32_t sym) {
    for (int i = 0; i < RS_ATTR_COUNT; i++)
        if (rs->attr_syms[i] == sym) return i;
    return -1; /* unknown attr — ignore the row (forward-compatible) */
}

/* ── Row collector (collect-then-mutate) ──────────────────────────────── */
/*
 * Growable buffer of collected tuples.  Rows are stored with a fixed stride
 * of 8 u32 (engine MAX_ARITY) plus a per-row arity, so one type serves the
 * arity-4 attr scan, the arity-3 instr scan, the arity-5 amend scan and the
 * add_run undo log.
 */
#define RS_ROW_STRIDE 8

typedef struct {
    uint32_t *rows;    /* n * RS_ROW_STRIDE */
    uint8_t  *arities; /* n */
    size_t    n, cap;
    int       error;   /* OOM during collection */
} rowbuf;

static int rowbuf_init(rowbuf *rb) {
    rb->cap = 16;
    rb->n = 0;
    rb->error = 0;
    rb->rows = malloc(rb->cap * RS_ROW_STRIDE * sizeof(uint32_t));
    rb->arities = malloc(rb->cap);
    if (!rb->rows || !rb->arities) {
        free(rb->rows); free(rb->arities);
        rb->rows = NULL; rb->arities = NULL;
        return -1;
    }
    return 0;
}

static void rowbuf_free(rowbuf *rb) {
    free(rb->rows);
    free(rb->arities);
    rb->rows = NULL;
    rb->arities = NULL;
    rb->n = rb->cap = 0;
}

static int rowbuf_push(rowbuf *rb, const uint32_t *cols, uint8_t arity) {
    if (rb->n == rb->cap) {
        size_t ncap = rb->cap * 2;
        uint32_t *nr = realloc(rb->rows, ncap * RS_ROW_STRIDE * sizeof(uint32_t));
        if (!nr) { rb->error = 1; return -1; }
        rb->rows = nr;
        uint8_t *na = realloc(rb->arities, ncap);
        if (!na) { rb->error = 1; return -1; }
        rb->arities = na;
        rb->cap = ncap;
    }
    memcpy(rb->rows + rb->n * RS_ROW_STRIDE, cols, arity * sizeof(uint32_t));
    rb->arities[rb->n] = arity;
    rb->n++;
    return 0;
}

/* dl_prefix callback: COPY the tuple out; NEVER mutate the db here. */
static int rs_collect_cb(const uint32_t *cols, uint8_t arity, void *user) {
    rowbuf *rb = user;
    if (rowbuf_push(rb, cols, arity) != 0)
        return 0; /* flagged in rb->error; finish the walk */
    return 0;
}

/* Collect every row of `rel` whose first column == run_sym. */
static int rs_collect_run_rows(RunStore *rs, const char *rel, uint8_t arity,
                               uint32_t run_sym, rowbuf *rb) {
    uint32_t lead[1] = { run_sym };
    if (rowbuf_init(rb) != 0) return -1;
    if (dl_prefix(rs->db, rel, lead, 1, rs_collect_cb, rb) < 0 && !rb->error) {
        rowbuf_free(rb);
        return -1;
    }
    if (rb->error) {
        rowbuf_free(rb);
        return -1;
    }
    (void)arity;
    return 0;
}

/* Delete every row of `rel` whose first column == run_sym, outside any
 * walker callback (defined below, used by add/remove). */
static void rs_sweep(RunStore *rs, const char *rel, uint8_t arity,
                     uint32_t run_sym);

/* Sweep a run_id's rows out of all three payload relations. */
static void rs_sweep_orphans(RunStore *rs, uint32_t run_sym) {
    rs_sweep(rs, RS_REL_ATTR, 4, run_sym);
    rs_sweep(rs, RS_REL_INSTR, 3, run_sym);
    rs_sweep(rs, RS_REL_AMEND, 5, run_sym);
}

/* ── Presence + resolve helpers (call with lock held) ─────────────────── */

/* Intern run_id and require the `run` presence fact.  0 = found (*sym_out
 * set), -1 = absent.  NOTE: interning on lookup grows the interner by one
 * inert symbol for unknown ids; the engine has no read-only resolve. */
static int rs_require_locked(RunStore *rs, const char *run_id,
                             uint32_t *sym_out) {
    uint32_t sym = dl_intern_str(rs->db, run_id);
    if (sym == RS_SYM_NULL) return -1;
    if (!dl_lookup(rs->db, RS_REL_RUN, &sym, 1)) return -1;
    *sym_out = sym;
    return 0;
}

/* Resolve + strdup an interned value.  sym 0 (the null-string sentinel)
 * always maps to NULL — required fields never carry 0 by construction, and
 * the caller decides whether NULL means "absent" (nullable attr) or "bad
 * item" (orphan sym on a required attr). */
static char *rs_sym_str(dl_db *db, uint32_t sym) {
    const char *s;
    if (sym == RS_SYM_NULL) return NULL;
    s = dl_intern_str_of(db, sym);
    if (!s) return NULL; /* orphan sym: interner failed to round-trip */
    return rs_strdup(s);
}

/* ── set_attr: the load-bearing mutable-field transition ──────────────── */
/*
 * rs_set_attr_core(run_sym, attr, new_val):
 *   1. collect ALL (R,attr,*,*) rows via dl_prefix(k=2) — collect-then-mutate;
 *   2. current value = the max-seq row (idempotency compares against THAT
 *      row, i.e. ALL rows via the max, never just the first);
 *   3. if the current row already holds new_val and it is the only row,
 *      nothing to do (Python set_x saves unconditionally, but skipping an
 *      identical rewrite avoids WAL churn and is observationally equal);
 *   4. ADD the new row (seq = max+1) FIRST — durable before we touch old;
 *   5. DELETE every collected row that is not being kept as current.
 * A crash between 4 and 5 leaves {old,new}; the max-seq read is already
 * correct and the NEXT set_attr collapses the duplicate.
 */
static int rs_set_attr_core(RunStore *rs, uint32_t run_sym, rs_attr_id a,
                            uint32_t new_val, char *err, size_t errcap) {
    const uint32_t asym = rs->attr_syms[a];
    uint32_t lead[2] = { run_sym, asym };
    rowbuf rb;
    size_t best = (size_t)-1;
    uint32_t best_seq = 0;
    int already;

    if (rowbuf_init(&rb) != 0) {
        RS_ERR(err, errcap, "out of memory");
        return -1;
    }
    if (dl_prefix(rs->db, RS_REL_ATTR, lead, 2, rs_collect_cb, &rb) < 0 &&
        !rb.error) {
        rowbuf_free(&rb);
        RS_ERR(err, errcap, "attr scan failed");
        return -1;
    }
    if (rb.error) {
        rowbuf_free(&rb);
        RS_ERR(err, errcap, "out of memory scanning attr rows");
        return -1;
    }

    for (size_t i = 0; i < rb.n; i++) {
        uint32_t seq = rb.rows[i * RS_ROW_STRIDE + 2];
        if (best == (size_t)-1 || seq > best_seq) {
            best = i;
            best_seq = seq;
        }
    }

    already = (best != (size_t)-1) &&
              (rb.rows[best * RS_ROW_STRIDE + 3] == new_val);

    if (!(already && rb.n == 1)) {
        uint32_t new_seq = (best == (size_t)-1) ? 0u : best_seq + 1u;
        if (best != (size_t)-1 && best_seq >= UINT32_MAX - 1u) {
            rowbuf_free(&rb);
            RS_ERR(err, errcap, "attr '%s' seq exhausted", RS_ATTR_META[a].name);
            return -1;
        }
        if (!already) {
            uint32_t fact[4] = { run_sym, asym, new_seq, new_val };
            if (dl_add_fact(rs->db, RS_REL_ATTR, fact, 4) < 0) {
                rowbuf_free(&rb);
                RS_ERR(err, errcap, "cannot store attr '%s'",
                       RS_ATTR_META[a].name);
                return -1;
            }
            /* TEST-ONLY: emulate a crash between the ADD and the DELETE. */
            rs_test_crash("RS_CRASH_AFTER_ADD");
        }
        /* DELETE after: everything collected except a kept current row. */
        for (size_t i = 0; i < rb.n; i++) {
            if (already && i == best) continue;
            uint32_t *row = rb.rows + i * RS_ROW_STRIDE;
            /* Lenient: a failed delete leaves a duplicate that the next
             * set_attr self-heals (the design tolerates it). */
            (void)dl_delete_fact(rs->db, RS_REL_ATTR, row, 4);
        }
    }
    rowbuf_free(&rb);
    return 0;
}

static int rs_set_attr_str_locked(RunStore *rs, uint32_t run_sym,
                                  rs_attr_id a, const char *val,
                                  char *err, size_t errcap) {
    uint32_t sym = RS_SYM_NULL;
    if (val) {
        if (strlen(val) > RS_INTERN_MAX) {
            RS_ERR(err, errcap, "value for attr '%s' too long (max %u bytes)",
                   RS_ATTR_META[a].name, RS_INTERN_MAX);
            return -1;
        }
        sym = dl_intern_str(rs->db, val);
        if (sym == RS_SYM_NULL) {
            RS_ERR(err, errcap, "cannot intern value for attr '%s'",
                   RS_ATTR_META[a].name);
            return -1;
        }
    }
    return rs_set_attr_core(rs, run_sym, a, sym, err, errcap);
}

static int rs_set_attr_int_locked(RunStore *rs, uint32_t run_sym,
                                  rs_attr_id a, int32_t v,
                                  char *err, size_t errcap) {
    return rs_set_attr_core(rs, run_sym, a, (uint32_t)v, err, errcap);
}

/* ── Write helpers used by add (recorded for rollback) ────────────────── */

static int rs_put_attr_str(RunStore *rs, uint32_t run_sym, rs_attr_id a,
                           const char *val, rowbuf *undo) {
    uint32_t fact[4];
    if (!val) return 0; /* nullable field unset: no row (== null) */
    if (strlen(val) > RS_INTERN_MAX) return -1;
    fact[0] = run_sym;
    fact[1] = rs->attr_syms[a];
    fact[2] = 0u; /* immutable attrs: seq 0, written once at add */
    fact[3] = dl_intern_str(rs->db, val);
    if (fact[3] == RS_SYM_NULL) return -1;
    /* 1 added / 0 already present both leave the fact in place (a sweep
     * above guarantees absence, but replayed-WAL oddities are tolerated). */
    if (dl_add_fact(rs->db, RS_REL_ATTR, fact, 4) < 0) return -1;
    if (undo && rowbuf_push(undo, fact, 4) != 0) return -1;
    return 0;
}

static int rs_put_attr_int(RunStore *rs, uint32_t run_sym, rs_attr_id a,
                           int32_t v, rowbuf *undo) {
    uint32_t fact[4] = { run_sym, rs->attr_syms[a], 0u, (uint32_t)v };
    if (dl_add_fact(rs->db, RS_REL_ATTR, fact, 4) < 0) return -1;
    if (undo && rowbuf_push(undo, fact, 4) != 0) return -1;
    return 0;
}

/* ── Record reconstruction (get / list) ───────────────────────────────── */

typedef struct {
    int      present[RS_ATTR_COUNT];
    uint32_t val[RS_ATTR_COUNT];
    uint32_t seq[RS_ATTR_COUNT];
} attr_snap;

static int rs_scan_attrs(RunStore *rs, uint32_t run_sym, attr_snap *as) {
    rowbuf rb;
    memset(as, 0, sizeof *as);
    if (rs_collect_run_rows(rs, RS_REL_ATTR, 4, run_sym, &rb) != 0)
        return -1;
    for (size_t i = 0; i < rb.n; i++) {
        const uint32_t *row = rb.rows + i * RS_ROW_STRIDE;
        int aid = rs_attr_id_of(rs, row[1]);
        if (aid < 0) continue; /* unknown attr: ignore (forward-compat) */
        if (!as->present[aid] || row[2] > as->seq[aid]) {
            as->present[aid] = 1;
            as->seq[aid] = row[2];
            as->val[aid] = row[3];
        }
    }
    rowbuf_free(&rb);
    return 0;
}

/* Reassemble instructions from instr chunks (rows arrive in ascending
 * chunk_idx order — u32BE key order).  Strict: an unresolvable chunk marks
 * the item bad. */
static int rs_load_instructions(RunStore *rs, uint32_t run_sym,
                                char **out) {
    rowbuf rb;
    *out = NULL;
    if (rs_collect_run_rows(rs, RS_REL_INSTR, 3, run_sym, &rb) != 0)
        return -1;

    size_t total = 0;
    const char **chunks = NULL;
    size_t n = rb.n;
    if (n > 0) {
        chunks = malloc(n * sizeof *chunks);
        if (!chunks) { rowbuf_free(&rb); return -1; }
        for (size_t i = 0; i < n; i++) {
            uint32_t sym = rb.rows[i * RS_ROW_STRIDE + 2];
            const char *s = (sym == RS_SYM_NULL)
                ? NULL : dl_intern_str_of(rs->db, sym);
            if (!s) { /* orphan sym: fail-open to "bad item" */
                free(chunks);
                rowbuf_free(&rb);
                return -1;
            }
            chunks[i] = s;
            total += strlen(s);
        }
    }
    char *buf = malloc(total + 1);
    if (!buf) { free(chunks); rowbuf_free(&rb); return -1; }
    size_t off = 0;
    for (size_t i = 0; i < n; i++) {
        size_t l = strlen(chunks[i]);
        memcpy(buf + off, chunks[i], l);
        off += l;
    }
    buf[off] = '\0';
    free(chunks);
    rowbuf_free(&rb);
    *out = buf;
    return 0;
}

/* Amend rows arrive in ascending (seq, ts, text, applied) order.  Group by
 * seq: (ts, text) from the group's rows (identical by construction — mark
 * only flips `applied`), applied = OR over the group ("any applied=1 row
 * wins": the crash-duplicate self-heal rule). */
typedef struct {
    rs_amend *arr;
    size_t    n, cap;
} amend_buf;

static int amend_buf_push(amend_buf *ab, const char *ts, const char *text,
                          int applied) {
    if (ab->n == ab->cap) {
        size_t ncap = ab->cap ? ab->cap * 2 : 8;
        rs_amend *na = realloc(ab->arr, ncap * sizeof *na);
        if (!na) return -1;
        ab->arr = na;
        ab->cap = ncap;
    }
    ab->arr[ab->n].ts = rs_strdup(ts);
    ab->arr[ab->n].text = rs_strdup(text);
    ab->arr[ab->n].applied = applied;
    if (!ab->arr[ab->n].ts || !ab->arr[ab->n].text) return -1;
    ab->n++;
    return 0;
}

/* Shared by rs_load_amends (into an AgentRun) and snapshot_amends. */
static int rs_scan_amends(RunStore *rs, uint32_t run_sym, amend_buf *ab) {
    rowbuf rb;
    memset(ab, 0, sizeof *ab);
    if (rs_collect_run_rows(rs, RS_REL_AMEND, 5, run_sym, &rb) != 0)
        return -1;

    int have_cur = 0;
    uint32_t cur_seq = 0;
    const char *cur_ts = NULL, *cur_text = NULL;
    int cur_applied = 0;

    for (size_t i = 0; i < rb.n; i++) {
        const uint32_t *row = rb.rows + i * RS_ROW_STRIDE;
        uint32_t seq = row[1];
        if (!have_cur || seq != cur_seq) {
            if (have_cur) {
                if (amend_buf_push(ab, cur_ts, cur_text, cur_applied) != 0)
                    goto oom;
            }
            have_cur = 1;
            cur_seq = seq;
            cur_ts = (row[2] == RS_SYM_NULL)
                ? NULL : dl_intern_str_of(rs->db, row[2]);
            cur_text = (row[3] == RS_SYM_NULL)
                ? NULL : dl_intern_str_of(rs->db, row[3]);
            cur_applied = 0;
            if (!cur_ts || !cur_text) {
                /* Orphan sym: drop this amend entry (the amend list is
                 * peripheral; keep the run usable, like Python loading
                 * amends verbatim). */
                have_cur = 0;
                continue;
            }
        }
        if (row[4] != 0) cur_applied = 1;
    }
    if (have_cur) {
        if (amend_buf_push(ab, cur_ts, cur_text, cur_applied) != 0)
            goto oom;
    }
    rowbuf_free(&rb);
    return 0;
oom:
    rowbuf_free(&rb);
    for (size_t i = 0; i < ab->n; i++) {
        free(ab->arr[i].ts);
        free(ab->arr[i].text);
    }
    free(ab->arr);
    memset(ab, 0, sizeof *ab);
    return -1;
}

/* Rebuild the full AgentRun from facts.  NULL if the item is "bad" (a
 * required attr missing, or any referenced symbol unresolvable) — the
 * ignores-bad-items policy. */
static AgentRun *rs_reconstruct(RunStore *rs, uint32_t run_sym) {
    const char *rid = dl_intern_str_of(rs->db, run_sym);
    if (!rid) return NULL;

    attr_snap as;
    if (rs_scan_attrs(rs, run_sym, &as) != 0) return NULL;

    /* Required fields (Python dataclass positional args). */
    if (!as.present[RS_ATTR_AGENT] || !as.present[RS_ATTR_SLUG] ||
        !as.present[RS_ATTR_CWD])
        return NULL;

    AgentRun *r = calloc(1, sizeof *r);
    if (!r) return NULL;
    r->run_id = rs_strdup(rid);
    r->agent = rs_sym_str(rs->db, as.val[RS_ATTR_AGENT]);
    r->slug = rs_sym_str(rs->db, as.val[RS_ATTR_SLUG]);
    r->cwd = rs_sym_str(rs->db, as.val[RS_ATTR_CWD]);
    if (!r->run_id || !r->agent || !r->slug || !r->cwd) {
        agentrun_free(r);
        return NULL;
    }

    /* Defaulted fields (dataclass defaults). */
    r->session_id = as.present[RS_ATTR_SESSION_ID]
        ? rs_sym_str(rs->db, as.val[RS_ATTR_SESSION_ID])
        : rs_strdup("");
    r->max_turns = as.present[RS_ATTR_MAX_TURNS]
        ? (int)(int32_t)as.val[RS_ATTR_MAX_TURNS] : 30;
    r->secrets_scope = as.present[RS_ATTR_SECRETS_SCOPE]
        ? rs_sym_str(rs->db, as.val[RS_ATTR_SECRETS_SCOPE])
        : rs_strdup("minimal");
    r->schedule_id = as.present[RS_ATTR_SCHEDULE_ID]
        ? rs_sym_str(rs->db, as.val[RS_ATTR_SCHEDULE_ID])
        : rs_strdup("");
    r->status = as.present[RS_ATTR_STATUS]
        ? rs_sym_str(rs->db, as.val[RS_ATTR_STATUS])
        : rs_strdup(RS_STATUS_QUEUED);
    r->created_at = as.present[RS_ATTR_CREATED_AT]
        ? rs_sym_str(rs->db, as.val[RS_ATTR_CREATED_AT])
        : rs_strdup("");
    r->paused_at = as.present[RS_ATTR_PAUSED_AT]
        ? rs_sym_str(rs->db, as.val[RS_ATTR_PAUSED_AT]) : NULL;
    r->last_turn_at = as.present[RS_ATTR_LAST_TURN_AT]
        ? rs_sym_str(rs->db, as.val[RS_ATTR_LAST_TURN_AT]) : NULL;
    if (as.present[RS_ATTR_EXIT_CODE]) {
        r->has_exit_code = 1;
        r->exit_code = (int)(int32_t)as.val[RS_ATTR_EXIT_CODE];
    }
    if (as.present[RS_ATTR_PID]) {
        r->has_pid = 1;
        r->pid = (int)(int32_t)as.val[RS_ATTR_PID];
    }

    /* A non-zero sym that fails to resolve (corrupt interner) => bad item. */
    if ((as.present[RS_ATTR_SESSION_ID] && !r->session_id) ||
        (as.present[RS_ATTR_SECRETS_SCOPE] && !r->secrets_scope) ||
        (as.present[RS_ATTR_SCHEDULE_ID] && !r->schedule_id) ||
        (as.present[RS_ATTR_STATUS] && !r->status) ||
        (as.present[RS_ATTR_CREATED_AT] && !r->created_at) ||
        (as.present[RS_ATTR_PAUSED_AT] &&
         as.val[RS_ATTR_PAUSED_AT] != RS_SYM_NULL && !r->paused_at) ||
        (as.present[RS_ATTR_LAST_TURN_AT] &&
         as.val[RS_ATTR_LAST_TURN_AT] != RS_SYM_NULL && !r->last_turn_at)) {
        agentrun_free(r);
        return NULL;
    }

    if (rs_load_instructions(rs, run_sym, &r->instructions) != 0) {
        agentrun_free(r);
        return NULL;
    }

    amend_buf ab;
    if (rs_scan_amends(rs, run_sym, &ab) != 0) {
        agentrun_free(r);
        return NULL;
    }
    r->amends = ab.arr;
    r->n_amends = ab.n;
    return r;
}

/* ── Free helpers ─────────────────────────────────────────────────────── */

void agentrun_free(AgentRun *r) {
    if (!r) return;
    free(r->run_id);
    free(r->agent);
    free(r->slug);
    free(r->instructions);
    free(r->cwd);
    free(r->session_id);
    free(r->secrets_scope);
    free(r->schedule_id);
    free(r->status);
    free(r->created_at);
    free(r->paused_at);
    free(r->last_turn_at);
    runstore_amends_free(r->amends, r->n_amends);
    free(r);
}

void runstore_list_free(AgentRun **runs, size_t n) {
    if (!runs) return;
    for (size_t i = 0; i < n; i++) agentrun_free(runs[i]);
    free(runs);
}

void runstore_amends_free(rs_amend *a, size_t n) {
    if (!a) return;
    for (size_t i = 0; i < n; i++) {
        free(a[i].ts);
        free(a[i].text);
    }
    free(a);
}

/* ── Lifecycle ────────────────────────────────────────────────────────── */

int runstore_open(RunStore *rs, const char *dir, char *err, size_t errcap) {
    if (!rs || !dir || !*dir) {
        RS_ERR(err, errcap, "invalid arguments to runstore_open");
        return -1;
    }
    memset(rs, 0, sizeof *rs);
    if (pthread_mutex_init(&rs->lock, NULL) != 0) {
        RS_ERR(err, errcap, "pthread_mutex_init failed");
        return -1;
    }
    int derr = 0;
    rs->db = dl_open2(dir, &derr);
    if (!rs->db) {
        pthread_mutex_destroy(&rs->lock);
        if (derr == DL_E_LOCKED)
            RS_ERR(err, errcap,
                   "store '%s' is locked by another writer (single-writer)",
                   dir);
        else
            RS_ERR(err, errcap, "cannot open store directory '%s'", dir);
        return -1;
    }
    rs->dir = rs_strdup(dir);

    if (dl_declare_relation(rs->db, RS_REL_RUN, 1) != 0 ||
        dl_declare_relation(rs->db, RS_REL_ATTR, 4) != 0 ||
        dl_declare_relation(rs->db, RS_REL_INSTR, 3) != 0 ||
        dl_declare_relation(rs->db, RS_REL_AMEND, 5) != 0) {
        dl_close(rs->db);
        rs->db = NULL;
        free(rs->dir);
        rs->dir = NULL;
        pthread_mutex_destroy(&rs->lock);
        RS_ERR(err, errcap, "cannot declare runstore relations in '%s'", dir);
        return -1;
    }

    for (int i = 0; i < RS_ATTR_COUNT; i++) {
        rs->attr_syms[i] = dl_intern_str(rs->db, RS_ATTR_META[i].name);
        if (rs->attr_syms[i] == RS_SYM_NULL) {
            dl_close(rs->db);
            rs->db = NULL;
            free(rs->dir);
            rs->dir = NULL;
            pthread_mutex_destroy(&rs->lock);
            RS_ERR(err, errcap, "cannot intern attr name '%s'",
                   RS_ATTR_META[i].name);
            return -1;
        }
    }

    rs->max_runs = rs_env_int("VIBE_MAX_RUNS", 50, 1);
    rs->max_instr_chars = rs_env_int("VIBE_MAX_INSTRUCTIONS_CHARS", 32768, 0);
    return 0;
}

void runstore_close(RunStore *rs) {
    if (!rs) return;
    if (rs->db) {
        pthread_mutex_lock(&rs->lock);
        dl_close(rs->db); /* saves interner + compacts every relation */
        rs->db = NULL;
        pthread_mutex_unlock(&rs->lock);
    }
    free(rs->dir);
    rs->dir = NULL;
    pthread_mutex_destroy(&rs->lock);
}

/* ── add ──────────────────────────────────────────────────────────────── */

int runstore_add(RunStore *rs, const AgentRun *run, char *err, size_t errcap) {
    if (!rs || !rs->db) {
        RS_ERR(err, errcap, "store not open");
        return -1;
    }
    if (!run || !run->run_id || !*run->run_id ||
        !run->agent || !*run->agent ||
        !run->slug || !run->cwd || !run->instructions) {
        RS_ERR(err, errcap,
               "run_id, agent, slug, cwd and instructions are required");
        return -1;
    }

    pthread_mutex_lock(&rs->lock);

    const char *instr = run->instructions;
    size_t ilen = strlen(instr);

    uint32_t run_sym = dl_intern_str(rs->db, run->run_id);
    if (run_sym == RS_SYM_NULL) {
        RS_ERR(err, errcap, "run_id too long to intern (max %u bytes)",
               RS_INTERN_MAX);
        pthread_mutex_unlock(&rs->lock);
        return -1;
    }
    if (dl_lookup(rs->db, RS_REL_RUN, &run_sym, 1)) {
        RS_ERR(err, errcap, "run '%.200s' already exists", run->run_id);
        pthread_mutex_unlock(&rs->lock);
        return -1;
    }
    uint64_t nruns = dl_count(rs->db, RS_REL_RUN);
    if (nruns == UINT64_MAX) {
        RS_ERR(err, errcap, "cannot count runs in '%s'", rs->dir);
        pthread_mutex_unlock(&rs->lock);
        return -1;
    }
    if (nruns >= (uint64_t)rs->max_runs) {
        RS_ERR(err, errcap,
               "maximum runs (%d) reached \xE2\x80\x94 remove a run first",
               rs->max_runs);
        pthread_mutex_unlock(&rs->lock);
        return -1;
    }
    if (ilen > (size_t)rs->max_instr_chars) {
        RS_ERR(err, errcap, "instructions too long (%zu chars); max %d",
               ilen, rs->max_instr_chars);
        pthread_mutex_unlock(&rs->lock);
        return -1;
    }

    /* GC crash-orphaned rows for this id: the presence fact is absent
     * (checked above), so ANY attr/instr/amend row keyed by run_sym is a
     * leftover from a crashed add — sweep it so the re-add is deterministic
     * (orphan instr chunks would otherwise reassemble into the new run's
     * instructions).  This is the plan's optional open-time GC, done lazily
     * at the point of reuse. */
    rs_sweep_orphans(rs, run_sym);

    /* AgentRun dataclass defaults, applied by the store (Python
     * __init__/__post_init__ equivalence). */
    char created_buf[48];
    const char *created_at = (run->created_at && *run->created_at)
        ? run->created_at
        : (rs_utcnow_iso(created_buf, sizeof created_buf), created_buf);
    const char *status = (run->status && *run->status)
        ? run->status : RS_STATUS_QUEUED;
    const char *session_id = run->session_id ? run->session_id : "";
    const char *secrets_scope = run->secrets_scope;
    const char *schedule_id = run->schedule_id ? run->schedule_id : "";

    rowbuf undo; /* attr(4) + instr(3) + amend(5) rows for rollback */
    int failed = rowbuf_init(&undo) != 0;

    /* 1. Scalar attr facts (immutable: seq 0). */
    if (!failed && rs_put_attr_str(rs, run_sym, RS_ATTR_AGENT,
                                   run->agent, &undo) != 0) failed = 1;
    if (!failed && rs_put_attr_str(rs, run_sym, RS_ATTR_SLUG,
                                   run->slug, &undo) != 0) failed = 1;
    if (!failed && rs_put_attr_str(rs, run_sym, RS_ATTR_CWD,
                                   run->cwd, &undo) != 0) failed = 1;
    if (!failed && rs_put_attr_str(rs, run_sym, RS_ATTR_SESSION_ID,
                                   session_id, &undo) != 0) failed = 1;
    if (!failed && rs_put_attr_int(rs, run_sym, RS_ATTR_MAX_TURNS,
                                   run->max_turns > 0 ? run->max_turns : 30,
                                   &undo) != 0) failed = 1;
    if (!failed && secrets_scope &&
        rs_put_attr_str(rs, run_sym, RS_ATTR_SECRETS_SCOPE,
                        secrets_scope, &undo) != 0) failed = 1;
    if (!failed && rs_put_attr_str(rs, run_sym, RS_ATTR_SCHEDULE_ID,
                                   schedule_id, &undo) != 0) failed = 1;
    if (!failed && rs_put_attr_str(rs, run_sym, RS_ATTR_STATUS,
                                   status, &undo) != 0) failed = 1;
    if (!failed && run->has_exit_code &&
        rs_put_attr_int(rs, run_sym, RS_ATTR_EXIT_CODE,
                        (int32_t)run->exit_code, &undo) != 0) failed = 1;
    if (!failed && run->has_pid &&
        rs_put_attr_int(rs, run_sym, RS_ATTR_PID,
                        (int32_t)run->pid, &undo) != 0) failed = 1;
    if (!failed && rs_put_attr_str(rs, run_sym, RS_ATTR_PAUSED_AT,
                                   run->paused_at, &undo) != 0) failed = 1;
    if (!failed && rs_put_attr_str(rs, run_sym, RS_ATTR_LAST_TURN_AT,
                                   run->last_turn_at, &undo) != 0) failed = 1;
    if (!failed && rs_put_attr_str(rs, run_sym, RS_ATTR_CREATED_AT,
                                   created_at, &undo) != 0) failed = 1;

    /* 2. Instructions, chunked to <= RS_INTERN_MAX bytes per interned
     *    symbol (the interner's hard limit). */
    for (size_t off = 0, idx = 0; !failed && off < ilen;
         off += RS_INTERN_MAX, idx++) {
        size_t clen = ilen - off;
        if (clen > RS_INTERN_MAX) clen = RS_INTERN_MAX;
        char chunk[RS_INTERN_MAX + 1];
        memcpy(chunk, instr + off, clen);
        chunk[clen] = '\0';
        uint32_t csym = dl_intern_str(rs->db, chunk);
        uint32_t fact[3] = { run_sym, (uint32_t)idx,
                             csym ? csym : RS_SYM_NULL };
        if (csym == RS_SYM_NULL ||
            dl_add_fact(rs->db, RS_REL_INSTR, fact, 3) < 0 ||
            rowbuf_push(&undo, fact, 3) != 0) {
            failed = 1;
            break;
        }
    }

    /* 3. Amends carried by the incoming run (seq = position + 1). */
    for (size_t i = 0; !failed && i < run->n_amends; i++) {
        const rs_amend *a = &run->amends[i];
        if (!a || !a->text || strlen(a->text) > RS_INTERN_MAX) {
            failed = 1;
            break;
        }
        char ts_buf[48];
        const char *ts = (a->ts && *a->ts)
            ? a->ts : (rs_utcnow_iso(ts_buf, sizeof ts_buf), ts_buf);
        uint32_t ts_sym = dl_intern_str(rs->db, ts);
        uint32_t text_sym = dl_intern_str(rs->db, a->text);
        uint32_t fact[5] = { run_sym, (uint32_t)(i + 1), ts_sym, text_sym,
                             a->applied ? 1u : 0u };
        if (ts_sym == RS_SYM_NULL || text_sym == RS_SYM_NULL ||
            dl_add_fact(rs->db, RS_REL_AMEND, fact, 5) < 0 ||
            rowbuf_push(&undo, fact, 5) != 0) {
            failed = 1;
            break;
        }
    }

    /* TEST-ONLY: emulate a crash after the payload facts but BEFORE the
     * presence fact — asserts no phantom run appears. */
    if (!failed) rs_test_crash("RS_CRASH_MID_ADD");

    /* 4. COMMIT POINT: the presence fact goes LAST.  Until it lands, every
     *    row above is an invisible orphan. */
    if (!failed && dl_add_fact(rs->db, RS_REL_RUN, &run_sym, 1) < 0)
        failed = 1;

    if (failed) {
        /* Best-effort rollback (no presence fact was written, so even a
         * failed rollback leaves only invisible orphans). */
        for (size_t i = 0; i < undo.n; i++) {
            uint32_t *row = undo.rows + i * RS_ROW_STRIDE;
            (void)dl_delete_fact(rs->db,
                                 undo.arities[i] == 4 ? RS_REL_ATTR
                                 : undo.arities[i] == 3 ? RS_REL_INSTR
                                 : RS_REL_AMEND,
                                 row, undo.arities[i]);
        }
        rowbuf_free(&undo);
        RS_ERR(err, errcap, "cannot store run '%.200s'", run->run_id);
        pthread_mutex_unlock(&rs->lock);
        return -1;
    }
    rowbuf_free(&undo);
    pthread_mutex_unlock(&rs->lock);
    return 0;
}

/* ── get / list / remove ──────────────────────────────────────────────── */

AgentRun *runstore_get(RunStore *rs, const char *run_id) {
    if (!rs || !rs->db || !run_id || !*run_id) return NULL;
    pthread_mutex_lock(&rs->lock);
    AgentRun *r = NULL;
    uint32_t sym = dl_intern_str(rs->db, run_id);
    if (sym != RS_SYM_NULL && dl_lookup(rs->db, RS_REL_RUN, &sym, 1))
        r = rs_reconstruct(rs, sym);
    pthread_mutex_unlock(&rs->lock);
    return r;
}

int runstore_list(RunStore *rs, AgentRun ***out, size_t *out_n) {
    if (!rs || !rs->db || !out || !out_n) return -1;
    *out = NULL;
    *out_n = 0;
    pthread_mutex_lock(&rs->lock);

    rowbuf rb;
    if (rowbuf_init(&rb) != 0) {
        pthread_mutex_unlock(&rs->lock);
        return -1;
    }
    if (dl_prefix(rs->db, RS_REL_RUN, NULL, 0, rs_collect_cb, &rb) < 0 &&
        !rb.error) {
        rowbuf_free(&rb);
        pthread_mutex_unlock(&rs->lock);
        return -1;
    }
    if (rb.error) {
        rowbuf_free(&rb);
        pthread_mutex_unlock(&rs->lock);
        return -1;
    }

    AgentRun **arr = calloc(rb.n ? rb.n : 1, sizeof *arr);
    if (!arr) {
        rowbuf_free(&rb);
        pthread_mutex_unlock(&rs->lock);
        return -1;
    }
    size_t m = 0;
    for (size_t i = 0; i < rb.n; i++) {
        AgentRun *r = rs_reconstruct(rs, rb.rows[i * RS_ROW_STRIDE]);
        if (r) arr[m++] = r; /* bad items are skipped */
    }
    rowbuf_free(&rb);
    pthread_mutex_unlock(&rs->lock);
    *out = arr;
    *out_n = m;
    return 0;
}

/* Delete every row of `rel` keyed by run_sym (collect-then-mutate). */
static void rs_sweep(RunStore *rs, const char *rel, uint8_t arity,
                     uint32_t run_sym) {
    rowbuf rb;
    if (rs_collect_run_rows(rs, rel, arity, run_sym, &rb) != 0) return;
    for (size_t i = 0; i < rb.n; i++) {
        uint32_t *row = rb.rows + i * RS_ROW_STRIDE;
        /* Lenient: a failed sweep delete leaves an INERT orphan keyed by an
         * absent run — invisible to get/list, never resurrected. */
        (void)dl_delete_fact(rs->db, rel, row, arity);
    }
    rowbuf_free(&rb);
}

int runstore_remove(RunStore *rs, const char *run_id) {
    if (!rs || !rs->db || !run_id || !*run_id) return -1;
    pthread_mutex_lock(&rs->lock);
    uint32_t sym;
    if (rs_require_locked(rs, run_id, &sym) != 0) {
        pthread_mutex_unlock(&rs->lock);
        return -1; /* absent */
    }
    /* Presence FIRST: the run vanishes atomically at this delete. */
    if (dl_delete_fact(rs->db, RS_REL_RUN, &sym, 1) != 1) {
        pthread_mutex_unlock(&rs->lock);
        return -1;
    }
    rs_sweep_orphans(rs, sym);
    pthread_mutex_unlock(&rs->lock);
    return 0;
}

/* ── Setters (all = require + rs_set_attr_* under the lock) ───────────── */

int runstore_set_status(RunStore *rs, const char *run_id, const char *status) {
    if (!rs || !rs->db || !run_id || !status || !*status) return -1;
    pthread_mutex_lock(&rs->lock);
    uint32_t sym;
    int rc = rs_require_locked(rs, run_id, &sym);
    if (rc == 0)
        rc = rs_set_attr_str_locked(rs, sym, RS_ATTR_STATUS, status, NULL, 0);
    pthread_mutex_unlock(&rs->lock);
    return rc;
}

int runstore_set_session_id(RunStore *rs, const char *run_id, const char *sid) {
    if (!rs || !rs->db || !run_id || !sid) return -1;
    pthread_mutex_lock(&rs->lock);
    uint32_t sym;
    int rc = rs_require_locked(rs, run_id, &sym);
    if (rc == 0)
        rc = rs_set_attr_str_locked(rs, sym, RS_ATTR_SESSION_ID, sid,
                                    NULL, 0);
    pthread_mutex_unlock(&rs->lock);
    return rc;
}

int runstore_set_exit_code(RunStore *rs, const char *run_id, int code) {
    if (!rs || !rs->db || !run_id) return -1;
    pthread_mutex_lock(&rs->lock);
    uint32_t sym;
    int rc = rs_require_locked(rs, run_id, &sym);
    if (rc == 0)
        rc = rs_set_attr_int_locked(rs, sym, RS_ATTR_EXIT_CODE,
                                    (int32_t)code, NULL, 0);
    pthread_mutex_unlock(&rs->lock);
    return rc;
}

int runstore_set_pid(RunStore *rs, const char *run_id, int pid) {
    if (!rs || !rs->db || !run_id) return -1;
    pthread_mutex_lock(&rs->lock);
    uint32_t sym;
    int rc = rs_require_locked(rs, run_id, &sym);
    if (rc == 0)
        rc = rs_set_attr_int_locked(rs, sym, RS_ATTR_PID, (int32_t)pid,
                                    NULL, 0);
    pthread_mutex_unlock(&rs->lock);
    return rc;
}

int runstore_set_paused_at(RunStore *rs, const char *run_id, const char *iso) {
    if (!rs || !rs->db || !run_id) return -1;
    if (iso && strlen(iso) > RS_INTERN_MAX) return -1;
    pthread_mutex_lock(&rs->lock);
    uint32_t sym;
    int rc = rs_require_locked(rs, run_id, &sym);
    if (rc == 0)
        rc = rs_set_attr_str_locked(rs, sym, RS_ATTR_PAUSED_AT, iso,
                                    NULL, 0); /* NULL clears (sym 0) */
    pthread_mutex_unlock(&rs->lock);
    return rc;
}

int runstore_set_last_turn_at(RunStore *rs, const char *run_id,
                              const char *iso) {
    if (!rs || !rs->db || !run_id || !iso || !*iso) return -1;
    if (strlen(iso) > RS_INTERN_MAX) return -1;
    pthread_mutex_lock(&rs->lock);
    uint32_t sym;
    int rc = rs_require_locked(rs, run_id, &sym);
    if (rc == 0)
        rc = rs_set_attr_str_locked(rs, sym, RS_ATTR_LAST_TURN_AT, iso,
                                    NULL, 0);
    pthread_mutex_unlock(&rs->lock);
    return rc;
}

/* ── Amends ───────────────────────────────────────────────────────────── */

int runstore_append_amend(RunStore *rs, const char *run_id, const char *text) {
    if (!rs || !rs->db || !run_id || !text) return -1;
    if (strlen(text) > RS_INTERN_MAX) return -1; /* short user note only */
    pthread_mutex_lock(&rs->lock);

    uint32_t sym;
    int rc = rs_require_locked(rs, run_id, &sym);
    if (rc != 0) { pthread_mutex_unlock(&rs->lock); return -1; }

    rowbuf rb;
    if (rs_collect_run_rows(rs, RS_REL_AMEND, 5, sym, &rb) != 0) {
        pthread_mutex_unlock(&rs->lock);
        return -1;
    }
    uint32_t max_seq = 0;
    for (size_t i = 0; i < rb.n; i++) {
        uint32_t s = rb.rows[i * RS_ROW_STRIDE + 1];
        if (s > max_seq) max_seq = s;
    }
    rowbuf_free(&rb);
    if (max_seq >= UINT32_MAX - 1u) {
        pthread_mutex_unlock(&rs->lock);
        return -1;
    }

    char ts_buf[48];
    rs_utcnow_iso(ts_buf, sizeof ts_buf);
    uint32_t ts_sym = dl_intern_str(rs->db, ts_buf);
    uint32_t text_sym = dl_intern_str(rs->db, text);
    if (ts_sym == RS_SYM_NULL || text_sym == RS_SYM_NULL) {
        pthread_mutex_unlock(&rs->lock);
        return -1;
    }
    uint32_t fact[5] = { sym, max_seq + 1u, ts_sym, text_sym, 0u };
    if (dl_add_fact(rs->db, RS_REL_AMEND, fact, 5) != 1) {
        pthread_mutex_unlock(&rs->lock);
        return -1;
    }
    pthread_mutex_unlock(&rs->lock);
    return 0;
}

int runstore_mark_amend_applied(RunStore *rs, const char *run_id) {
    if (!rs || !rs->db || !run_id || !*run_id) return -1;
    pthread_mutex_lock(&rs->lock);

    uint32_t sym;
    int rc = rs_require_locked(rs, run_id, &sym);
    if (rc != 0) { pthread_mutex_unlock(&rs->lock); return -1; }

    rowbuf rb;
    if (rs_collect_run_rows(rs, RS_REL_AMEND, 5, sym, &rb) != 0) {
        pthread_mutex_unlock(&rs->lock);
        return -1;
    }
    for (size_t i = 0; i < rb.n; i++) {
        uint32_t *row = rb.rows + i * RS_ROW_STRIDE;
        if (row[4] != 0) continue; /* already applied */
        /* `applied` is monotonic 0 -> 1: ADD the applied=1 row FIRST (a
         * duplicate add returns 0 harmlessly if a previous crash left it),
         * then DELETE the applied=0 row.  Read rule: any 1-row wins, so a
         * crash between the two is already read correctly. */
        uint32_t fact[5] = { row[0], row[1], row[2], row[3], 1u };
        if (dl_add_fact(rs->db, RS_REL_AMEND, fact, 5) < 0) {
            rowbuf_free(&rb);
            pthread_mutex_unlock(&rs->lock);
            return -1;
        }
        /* TEST-ONLY: emulate a crash between the applied=1 ADD and the
         * applied=0 DELETE. */
        rs_test_crash("RS_CRASH_AFTER_ADD");
        (void)dl_delete_fact(rs->db, RS_REL_AMEND, row, 5);
    }
    rowbuf_free(&rb);
    pthread_mutex_unlock(&rs->lock);
    return 0;
}

int runstore_snapshot_amends(RunStore *rs, const char *run_id,
                             rs_amend **out, size_t *out_n) {
    if (!rs || !rs->db || !run_id || !out || !out_n) return -1;
    *out = NULL;
    *out_n = 0;
    pthread_mutex_lock(&rs->lock);

    uint32_t sym;
    int rc = rs_require_locked(rs, run_id, &sym);
    if (rc != 0) { pthread_mutex_unlock(&rs->lock); return -1; }

    amend_buf ab;
    if (rs_scan_amends(rs, sym, &ab) != 0) {
        pthread_mutex_unlock(&rs->lock);
        return -1;
    }
    pthread_mutex_unlock(&rs->lock);
    *out = ab.arr;
    *out_n = ab.n;
    return 0;
}

/* ── Audit log (JSONL sidecar, best-effort) ───────────────────────────── */

/* JSON-escape into a fresh malloc'd buffer (Python json.dumps with
 * ensure_ascii=False: pass UTF-8 through, escape quotes, backslash and
 * C0 controls).  NULL on OOM. */
static char *rs_json_escape(const char *s) {
    if (!s) s = "";
    size_t n = strlen(s);
    char *out = malloc(n * 6 + 1); /* worst case \u00XX per byte */
    if (!out) return NULL;
    char *p = out;
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        switch (c) {
        case '"':  *p++ = '\\'; *p++ = '"';  break;
        case '\\': *p++ = '\\'; *p++ = '\\'; break;
        case '\n': *p++ = '\\'; *p++ = 'n';  break;
        case '\r': *p++ = '\\'; *p++ = 'r';  break;
        case '\t': *p++ = '\\'; *p++ = 't';  break;
        case '\b': *p++ = '\\'; *p++ = 'b';  break;
        case '\f': *p++ = '\\'; *p++ = 'f';  break;
        default:
            if (c < 0x20) p += sprintf(p, "\\u%04x", c);
            else *p++ = (char)c;
        }
    }
    *p = '\0';
    return out;
}

int runstore_audit_append(const char *audit_path, const char *action,
                          const char *run_id, const char *detail) {
    if (!audit_path || !action) return 0; /* nothing sensible to do */
    char ts[48];
    rs_utcnow_iso(ts, sizeof ts);
    char *ea = rs_json_escape(action);
    char *er = rs_json_escape(run_id);
    char *ed = rs_json_escape(detail);
    if (!ea || !er || !ed) { free(ea); free(er); free(ed); return 0; }
    FILE *f = fopen(audit_path, "a");
    if (!f) { /* best-effort: absorb like jobs.py's try/except OSError */
        free(ea); free(er); free(ed);
        return 0;
    }
    /* Python json.dumps default separators: ", " and ": ". */
    fprintf(f, "{\"ts\": \"%s\", \"action\": \"%s\", "
               "\"run_id\": \"%s\", \"detail\": \"%s\"}\n",
            ts, ea, er, ed);
    fclose(f);
    free(ea); free(er); free(ed);
    return 0;
}
