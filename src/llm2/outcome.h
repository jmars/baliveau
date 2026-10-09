/* src/llm2/outcome.h — THE OBSERVATION LOOP: the durable activation-attempt
 * record, the store's own outcome files, and the RULE the boot path applies.
 *
 * WHY THIS EXISTS.  A never-settling OSCILLATOR was measured on B2's arm 2:
 * the agent activates a config that crashes the boot, fx-init recovers by
 * republishing older good content AS A NEW HIGHER VERSION (content goes back,
 * the version number goes UP), and — because the agent service lives in the
 * RESTORED bracket — it re-runs, re-reads its FIXED fixture and RE-CREATES the
 * failure.  Versions ratchet ~+2/cycle and <store>/.bootlog grows a failed line
 * per cycle, forever.  The agent is supposed to LOOK AT THE ROLL-FORWARD, see
 * what went wrong and not do it again.  This unit mechanises that step so the
 * machinery cannot re-act blindly (a model can supply judgement later; the
 * mechanism must not need one).
 *
 * THREE PIECES, all of them plain files:
 *
 *   1. THE OUTCOME, read from the store — the SAME source fx-init judges on,
 *      and readable with NO channel (the runtime DB is behind PID1's
 *      process-lifetime lock; these are not):
 *        <store>/.db/snapshots/CURRENT   "<version>\n" — the generation this
 *                                        boot is running (fx-init's own
 *                                        store_current_of reads the same file)
 *        <store>/.bootlog                "<version> <status> <epoch>" per boot,
 *                                        status in ok | failed | in-progress |
 *                                        shutdown
 *   2. THE ATTEMPT, recorded durably by the HARNESS ITSELF.  An agent-driven
 *      activation writes NO rt_effect("activate") and updates no runtime
 *      relation, so the correlation "the thing that broke was the thing I just
 *      did" CANNOT come from the system — the harness's own durable state is
 *      the ONLY causal link.  It lives under VIBE_RUNTIME_DIR (B1 proved that
 *      is /fx/disk/agent-data on the virtio disk), so it outlives the reboot:
 *        <data-dir>/attempts.jsonl      append-only, one record per line:
 *          "<epoch> <task> <step> <session> <run> <version> <config>"
 *        step = attempt (recorded BEFORE the tool call is dispatched, so the
 *        intent is durable even if the call kills the machine) | result (the
 *        outcome the verb returned) | done (this task ran to completion) |
 *        agent (this TASK ID belongs to this AGENT — the last field carries the
 *        agent NAME instead of a config path; written once per task, and the
 *        reason the boot can say so when a task identity DRIFTS, see below).
 *        The last field (config | agent name) may contain spaces; the other
 *        fields are single tokens (session/run are validated identifiers,
 *        ^[A-Za-z0-9._-]+$, and task is 16 hex).   Every field is written
 *        through one_line(), so CR/LF cannot forge a second record line.
 *        ORDER IS MEANING: the file is append-only and fx_outcome_record is
 *        its ONLY writer, so line order IS write order, and `done` is only
 *        ever read as settling the attempts that PRECEDE it.  A later
 *        attempt line SUSPENDS the done — a done that predates an
 *        UNACCOUNTED attempt (a --resume/--reconsider run that died before
 *        its tool result) does not settle it — and the suspension ends the
 *        moment that attempt is itself ACCOUNTED: a result line after it
 *        puts the done back in force.  A later attempt therefore clears the
 *        done ONLY while it is unaccounted; done -> attempt -> result is a
 *        COMPLETED task someone re-attempted (whose activation took), not a
 *        licence to issue a third activation (see fx_outcome_record_load).
 *   3. THE RULE, applied at the START of every run (the boot path):
 *
 *        "if the generation I am running in is not the one I activated,
 *         my activation failed — do not repeat it."
 *
 *      made precise against the bootlog, because "current != mine" alone
 *      cannot tell a FAILED activation from one that succeeded and was later
 *      superseded by another activation:
 *
 *        A = the generation the last recorded activation for this task produced
 *        C = <store>/.db/snapshots/CURRENT (the generation this boot runs)
 *
 *        "done in force" = a done line FOLLOWS the last attempt, OR a done
 *        line PREDATES it and that attempt is itself ACCOUNTED.  ACCOUNTED
 *        means a result line follows the attempt — INCLUDING one that named no
 *        generation (a v0 result): the run reached a verdict about its own
 *        activation, so the attempt is settled even though the activation is
 *        not.  A done line never settles an attempt that is still unaccounted —
 *        but a completed task stays completed once no unaccounted activation is
 *        left to settle.
 *
 *        THE ROWS BELOW OVERLAP ON ONE CELL and are evaluated IN THE ORDER
 *        WRITTEN, which decides it: the bootlog verdict on A is reached BEFORE
 *        the C == A comparison.  So for A ok AND C == A with no done, the
 *        SUPERSEDED row decides, not the RUN row (MEASURED — re-derived and
 *        driven by hand in the ordering review).  The list is a precedence
 *        order, not a set of disjoint patterns.
 *
 *        no activation recorded, not done        -> RUN
 *        no activation recorded, done in force   -> ALREADY_DONE (do not re-run)
 *        A failed in the bootlog                 -> ACTIVATION_FAILED
 *        A ok in the bootlog, done in force      -> ALREADY_DONE (it took; a
 *                                                   later activation superseded it)
 *        A ok in the bootlog, NOT done           -> SUPERSEDED (it booted, but
 *                                                   nothing on record says the
 *                                                   TASK finished: stop, and say
 *                                                   so honestly — "it took" is not
 *                                                   "it is complete")
 *        C == A, done in force                   -> ALREADY_DONE (the activation
 *                                                   took AND the task completed —
 *                                                   including the done ->
 *                                                   attempt -> result order: a
 *                                                   completed task someone
 *                                                   re-attempted is not a licence
 *                                                   to issue a THIRD activation)
 *        C == A, no done                         -> RUN (the ordinary re-run)
 *        A unaccounted (no result line, or the result named no generation),
 *          done in force                         -> ALREADY_DONE (complete wins:
 *                                                   the done follows the attempt,
 *                                                   or the attempt is accounted)
 *        A unaccounted, done BEFORE the attempt  -> UNRESOLVED (a done line may
 *                                                   only settle attempts that
 *                                                   PRECEDE it)
 *        A recorded with a version that was never
 *          judged, C != A                        -> UNRESOLVED (the store cannot
 *                                                   account for the activation —
 *                                                   a conservative stop even when
 *                                                   a done is in force)
 *        otherwise                               -> UNRESOLVED
 *
 *      ACTIVATION_FAILED, SUPERSEDED and UNRESOLVED all STOP: the task is NOT
 *      re-run and no further activation is issued.  The refusal exits 0, and
 *      WHY THAT IS SAFE is a property of the CALLER's service, not of this
 *      code: fx-init pins "failed" for a service that EXITS during the grace
 *      window only when that service is NON-console, and ignores the exit
 *      status entirely — a service declared `console = Some "console"` is
 *      EXEMPT from that verdict whatever its exit status.  Both payloads
 *      declare the agent service console (and assert it), so the refusal's
 *      exit 0 cannot pin a failure on the healthy generation.  A NON-console
 *      agent would turn this refusal into a new roll-forward oscillator: the
 *      refusal pins "v_C failed" on the rolled-forward generation, the next
 *      boot rolls forward again, the agent refuses again.  See
 *      tests/qemu-agent-observe.sh's console pin.
 *
 *      THE WAY OUT.  Every refusal is permanent until the RECORD changes: a
 *      record is only ever settled by a LATER COMPLETED run of the same task
 *      (which writes `done`), so the two legitimate escapes are an operator
 *      re-run with --reconsider, and removing this task's lines from
 *      <data-dir>/attempts.jsonl.  Every STOP report names them.
 *
 *      THE BOUND OF "NOT MODEL-REACHABLE" (a property of the TOOL TABLE,
 *      stated exactly, not a secrecy claim): inside the guest the model's
 *      only file-WRITING verb is fx_write, and its write surface is a
 *      CLOSED, HOST-DECLARED SET (FX_AGENT_WRITABLE, read at call time by
 *      tools/fx-verbs-server.c; a write outside the set is refused loudly,
 *      naming the set) — this record, the store, the bootlog and CURRENT are
 *      in NO default set, so no deployment that forgets the variable re-opens
 *      the record to the model.  fx_read CAN read the record: reads settle
 *      and erase nothing, and the loop's input is the harness's own
 *      boot-time consume, not the model's.  The set is closed because the
 *      table has no other file-writing shape (fx_write opens O_NOFOLLOW and
 *      can only create-or-truncate a regular file; no verb creates a symlink,
 *      renames, chmods or unlinks; fx_activate/fx_rollback write the store
 *      through the activator's own pinned argv).  What an ACTIVATED
 *      generation's own services could do to this file is beyond the verb
 *      table — and judging activations is exactly what this unit is for.
 *
 * NEVER GUESS THE STORE.  A verdict that needs the store and cannot read it
 * returns FX_VERDICT_ERROR naming the path; the caller FAILS LOUDLY rather than
 * deciding on a store it picked itself.
 */
#ifndef OUTCOME_H
#define OUTCOME_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 16 hex task-id chars + NUL.  FxOutcomeTask = FNV-1a-64(agent "\x1f" prompt):
 * the task's identity, which is what a re-run must be judged against.  (The
 * PROMPT, not the session id: every boot of a service creates a NEW session, so
 * a session id cannot identify "the same task being repeated".) */
#define FX_OUTCOME_TASK_CAP 17
#define FX_OUTCOME_PATH_CAP 512
#define FX_OUTCOME_STATUS_CAP 32
#define FX_OUTCOME_MSG_CAP 2048

/* The longest record line the WRITER can produce — every field at the cap the
 * reader parses it back with, plus separators.  The reader's buffer MUST be at
 * least this big (it is: +2 for the newline and the NUL), or a legitimate record
 * would be silently skipped — which reads as "nothing on record" and RUNS.  It
 * was 768 once: smaller than the sum of the caps (a 255-char session plus a
 * 511-char config overflows it), so a pathological pair lost the record. */
#define FX_OUTCOME_LINE_CAP (2 * FX_OUTCOME_PATH_CAP + 384)

/* The store's two outcome files, relative to the store dir. */
#define FX_OUTCOME_CURRENT_FILE ".db/snapshots/CURRENT"
#define FX_OUTCOME_BOOTLOG_FILE ".bootlog"

typedef enum {
    FX_VERDICT_RUN = 0,        /* nothing to observe; run the task normally */
    FX_VERDICT_ACTIVATION_FAILED, /* the recorded activation is why we are here */
    FX_VERDICT_ALREADY_DONE,      /* the task completed, or its activation took
                                   * AND the task is recorded complete */
    FX_VERDICT_SUPERSEDED,        /* the activation TOOK, but nothing on record
                                   * says the TASK finished (no `done` marker) */
    FX_VERDICT_UNRESOLVED,        /* recorded activation, fate not accounted for */
    FX_VERDICT_ERROR              /* the store is unreadable: FAIL LOUDLY */
} FxVerdict;

/* What the rule read (everything but the store/rule text is from the record). */
typedef struct {
    char          task[FX_OUTCOME_TASK_CAP];
    int           has_attempt;   /* an activation attempt is recorded */
    int           has_result;    /* its outcome was recorded */
    unsigned long version;       /* the generation the activation produced */
    char          session[264];  /* the session that made the attempt (sid) */
    char          run[64];       /* the run that made the attempt (run_id) */
    char          config[FX_OUTCOME_PATH_CAP];
    unsigned long epoch;
    int           done;          /* a `done` is IN FORCE: one follows the last
                                  * recorded attempt, or one PREDATES an
                                  * attempt that is itself accounted (see the
                                  * rule table).  A done that predates an
                                  * UNACCOUNTED attempt does not count. */
    int           done_suspended;/* a done PREDATES the last attempt and that
                                  * attempt is still unaccounted: the done is
                                  * held in reserve and returns to force the
                                  * moment a result line accounts for it */
    unsigned long done_epoch;    /* the done line's own provenance — the report
                                  * names WHO completed the task, and these are
                                  * it.  Meaningful only when done==1; while a
                                  * done is suspended they keep the suspended
                                  * done's provenance so a reinstated done can
                                  * still name its run */
    char          done_session[264];
    char          done_run[64];
    unsigned long current;       /* C — read only when the rule needs it */
    int           have_current;
    char          bootlog_status[FX_OUTCOME_STATUS_CAP]; /* verdict for `version` */
} FxOutcome;

/* FNV-1a-64 of (agent, prompt) -> 16 lowercase hex chars in out (>= 17 bytes).
 * The task's identity across boots.  NULL/empty parts are allowed. */
void fx_outcome_task_id(const char *agent, const char *prompt, char *out, size_t cap);

/* ── the durable record (VIBE_RUNTIME_DIR) ───────────────────────────────── */

/* Append ONE record line to <data_dir>/attempts.jsonl and fsync it.  `step` is
 * "attempt" | "result" | "done"; `config` may be NULL/"" (written as "-").
 * Returns 0 on success, -1 on error (the caller warns, never aborts: a failing
 * record must not kill a run whose transcript is still durable). */
int fx_outcome_record(const char *data_dir, const char *task, const char *step,
                      const char *session, const char *run, unsigned long version,
                      const char *config);

/* Read <data_dir>/attempts.jsonl back and fill the record for `task`.
 * FAIL-OPEN per line (a malformed line is skipped, never fatal), like
 * ckpt_load.  A line is only accepted when it ENDS with a newline: a crash
 * mid-write leaves a PREFIX of a line, and a prefix that cuts inside a field
 * can still parse as a full field set (a truncated version token looks like a
 * version) — adopting that would decide a verdict from a corrupt record, the
 * one thing fail-open must never do.  `done` is POSITION-AWARE: it settles
 * only the attempts that PRECEDE it, so a LATER attempt line for the task
 * suspends it (the file is append-only with one writer, so line order is
 * write order — a `done` that predates a later unaccounted attempt must not
 * pre-empt it), and the suspension ends when a result line accounts for
 * that attempt: a later attempt clears the done ONLY while it is
 * unaccounted.  Returns 0 (even when nothing matched), -1 on OOM. */
int fx_outcome_record_load(const char *data_dir, const char *task, FxOutcome *out);

/* What the record says about WHO a task id belongs to (`agent` step lines). */
typedef struct {
    int  bound;    /* the record binds `task` to `agent` */
    int  drifted;  /* the record binds `agent` to some OTHER task id */
    char other_task[FX_OUTCOME_TASK_CAP]; /* the first such task id ("" if none) */
} FxOutcomeBind;

/* Scan <data_dir>/attempts.jsonl for the task<->agent BINDINGS.  This is how a
 * DRIFTED task identity is caught: the task id is FNV-1a-64(agent, prompt), so
 * a prompt that varies per boot makes every boot a NEW task — the record never
 * matches, every boot RUNs, and the observation loop is silently INERT.  The
 * caller uses `drifted` to say so LOUDLY.  Returns 0 (also when there is no
 * record), -1 on a missing/unopenable data dir. */
int fx_outcome_bindings(const char *data_dir, const char *task, const char *agent,
                        FxOutcomeBind *out);

/* ── the store's own outcome files ───────────────────────────────────────── */

/* Parse <store>/.db/snapshots/CURRENT (a decimal version).  Returns 0 and sets
 * *out, -1 (with a message in err) when the store or the file is
 * absent/unreadable — NEVER a guessed version. */
int fx_outcome_current(const char *store, unsigned long *out, char *err, size_t errcap);

/* Walk <store>/.bootlog: one call per parsed "<version> <status> <epoch>" line.
 * `cb` returns non-zero to stop the walk.  Returns the number of lines seen,
 * or -1 when the bootlog cannot be opened. */
int fx_outcome_bootlog_each(const char *store,
                            int (*cb)(void *u, unsigned long version,
                                      const char *status, unsigned long epoch),
                            void *u);

/* The verdict line ("ok" | "failed") the bootlog records for `version`.
 * Returns 1 and sets status_out, 0 when the bootlog holds no such line. */
int fx_outcome_bootlog_verdict(const char *store, unsigned long version,
                               char *status_out, size_t scap);

/* The LAST verdict line in the bootlog (ok | failed), i.e. what the previous
 * boot did.  Returns 1 and sets version_out/status_out, 0 when there is none. */
int fx_outcome_bootlog_last(const char *store, unsigned long *version_out,
                            char *status_out, size_t scap);

/* ── the rule ────────────────────────────────────────────────────────────── */

/* Apply the rule for `task`.  `store` may be NULL/"" — a verdict that needs it
 * then returns FX_VERDICT_ERROR (never a guess).  On a non-RUN verdict the
 * human-readable report is written to `text` (NUL-terminated, capped at
 * textcap); `err` is filled on FX_VERDICT_ERROR.  Fills *out with what it read.
 * Returns the verdict. */
FxVerdict fx_outcome_verdict(const char *data_dir, const char *task,
                             const char *store, const char *agent,
                             FxOutcome *out, char *text, size_t textcap,
                             char *err, size_t errcap);

#ifdef __cplusplus
}
#endif

#endif /* OUTCOME_H */
