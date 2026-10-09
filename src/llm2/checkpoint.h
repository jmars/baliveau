/* src/llm2/checkpoint.h — LAYER-2 S7 per-turn messages.jsonl checkpoint.
 *
 * Durable transcript + run state for the agent loop.  The transcript lives in a
 * messages.jsonl file (one chat message per line, JSON) — the SAME format
 * src/session.c's session_first_user_message already reads (role/type +
 * content; role=tool carries tool_call_id; role=assistant carries tool_calls
 * of {id,name,arguments}).  A future resume (S11) re-reads what ckpt_save
 * writes.
 *
 * This unit defines its OWN growable message-list API (CkptMessages) that uses
 * the LlmMsg/LlmToolCall model from agent_loop.h (the header types only — it is
 * independent of agent_loop.c internals, which the S6 reviewer noted are not
 * exposed).  Deep copies are owned by the CkptMessages and freed via
 * ckpt_messages_free.
 *
 * Durability-correctness surface (the L2 memory-safety + crash rules):
 *   - Every field is length-capped at CKPT_FIELD_CAP (256 KiB) / tool args at
 *     AGENT_ARGS_CAP (64 KiB) — content/tool-call args are attacker-shaped.
 *   - JSON is always built with yyjson_mut and parsed with yyjson_read; never
 *     hand-interpolated.  No sprintf on message-origin bytes.
 *   - ckpt_load is FAIL-OPEN: a malformed/unparseable line is skipped (like
 *     session.c's read loop), never a hard error.
 *   - Run state goes through the existing runstore DAFSA (reused, not
 *     re-derived); the thin ckpt_run_* helpers wrap runstore_open/add/set_*.
 */
#ifndef CHECKPOINT_H
#define CHECKPOINT_H

#include <stddef.h>

#include "agent_loop.h"   /* LlmMsg / LlmToolCall (header types only) */
#include "runstore.h"     /* RunStore / AgentRun for the run-state helpers */

#ifdef __cplusplus
extern "C" {
#endif

/* Hard cap on any single message field copied into a CkptMessages (content,
 * role, tool_call_id, tool id/name).  Tool-call *arguments* JSON is capped
 * tighter at AGENT_ARGS_CAP (64 KiB), from agent_loop.h. */
#define CKPT_FIELD_CAP (256u * 1024u)
#define CKPT_LINE_CAP (4u * 1024u * 1024u) /* 4 MiB max line length */

/* A growable, deep-owned list of LlmMsg.  Every string field + every tool_call
 * (and its id/name/arguments) is a fresh malloc'd copy owned by the list and
 * freed by ckpt_messages_free. */
typedef struct CkptMessages {
    LlmMsg *msgs;
    size_t  n;
    size_t  cap;
} CkptMessages;

/* Zero-init a CkptMessages (must call ckpt_messages_free if it grows). */
void ckpt_messages_init(CkptMessages *c);

/* Deep-copy one message into the list (growing it as needed).  Fields are
 * length-capped (CKPT_FIELD_CAP / AGENT_ARGS_CAP).  Returns 0 on success,
 * -1 on OOM (the list is left untouched). */
int ckpt_append(CkptMessages *c, const LlmMsg *msg);

/* Write the list to `path` as messages.jsonl: one compact JSON object per
 * line, '\n'-terminated (yyjson_mut_write + '\n'), byte-compatible with what
 * session.c reads.  Returns 0 on success, -1 on open/write/OOM error. */
int ckpt_save(const char *path, const CkptMessages *c);

/* Append ONE message to `path` as a messages.jsonl line (open O_APPEND, one
 * write(2) of "<json>\n", fsync, close) and return only once the line is
 * durable — the mid-run flush.  The line is byte-identical to the one
 * ckpt_save would write for the same message (same msg_to_json + newline).
 *
 * A single write() keeps a torn tail (crash mid-flush) a prefix of a line,
 * which ckpt_load skips FAIL-OPEN; ckpt_save at end-of-run rewrites the whole
 * file and so heals any torn tail.  Returns 0 on success, -1 on
 * open/write/fsync error (never fatal for the caller: overflowing the file
 * descriptor limit must not abort a run whose transcript ckpt_save will write
 * anyway). */
int ckpt_append_line(const char *path, const LlmMsg *m);

/* Read `path` back, parsing each non-blank line with yyjson_read and
 * replaying the same message list into `out` (which is zero-initialized).
 * FAIL-OPEN: malformed/oversized lines are skipped, never fatal.  Returns 0 on
 * success (even if some lines were skipped), -1 if the file cannot be opened.
 * On error *out is left zeroed. */
int ckpt_load(const char *path, CkptMessages *out);

/* Compaction: when c.n exceeds `max_msgs`, drop the OLDEST non-system
 * messages until the list fits.  All system (role=="system") messages are kept.
 * A synthetic summary system message ("[compacted: dropped N earlier
 * messages]") is PREPENDED so the dropped span is still accounted for (the full
 * backend-generated summary is S11+; a static marker is the S7 mechanic).
 *
 * New count = min(c.n, max_msgs) but never below 1 + (#system kept) — system
 * messages are never dropped.  Returns the new count.  If c.n <= max_msgs the
 * list is returned unchanged (returns c.n). */
size_t ckpt_compact(CkptMessages *c, size_t max_msgs);

/* Free everything owned by the list and zero it.  NULL-safe. */
void ckpt_messages_free(CkptMessages *c);

/* ── Thin run-state helpers over the existing runstore DAFSA ───────────────
 * These just wrap runstore_open / runstore_add / the set_* accessors so the
 * loop can persist durable run state (status, session_id, last_turn_at)
 * without knowing the runstore schema.  All return 0 on success, non-zero on
 * error; err/errcap mirror the runstore convention (may be NULL/0). */

int ckpt_run_open(RunStore *rs, const char *dir, char *err, size_t errcap);
void ckpt_run_close(RunStore *rs);
/* Add a fresh run (status defaults "queued", session_id "" via runstore_add). */
int ckpt_run_add(RunStore *rs, const char *run_id, const char *agent,
                 char *err, size_t errcap);
int ckpt_run_set_status(RunStore *rs, const char *run_id, const char *status);
int ckpt_run_set_session_id(RunStore *rs, const char *run_id, const char *sid);
int ckpt_run_set_last_turn_at(RunStore *rs, const char *run_id, const char *iso);

#ifdef __cplusplus
}
#endif

#endif /* CHECKPOINT_H */
