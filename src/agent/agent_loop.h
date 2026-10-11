/* src/agent/agent_loop.h — tool-call TURN loop.
 *
 * The single-turn tool-call iteration over the llm_backend.h interface:
 * send a message list -> stream -> detect tool_calls -> accumulate them into a
 * TurnResult (NO dispatch yet — dispatch is S6).
 *
 * Message model:
 *   - LlmMsg: one message in the conversation (role user|assistant|system|tool).
 *     `tool_call_id` is for role=tool messages (S6); `tool_calls` is for
 *     role=assistant messages carrying emitted tool calls (S6).  Both are empty
 *     for S4 (no tool msgs emitted, assistant tool_calls not yet carried back).
 *   - LlmToolCall: one tool call the model emitted in this turn (id + name +
 *     full arguments JSON).  Owned by the TurnResult.
 *
 * TurnResult is OWNED by the caller (stack-allocated in tests, freed via
 * agent_loop_free_turn).  Buffers (text / tool_calls / each call's fields) are
 * malloc'd grow buffers that the loop fills during the turn.
 *
 * Memory-safety (L2 rules): the request JSON is built with yyjson_mut (never
 * hand-concatenated); Delta slices are valid only for the synchronous sink
 * call, so the sink memcpy's every slice into the loop's OWN grow buffers
 * immediately; tool-call args are attacker-shaped and length-capped at
 * AGENT_ARGS_CAP (64 KiB); no strcpy/strcat/sprintf on network bytes; every
 * malloc/realloc checked.
 */
#ifndef AGENT_LOOP_H
#define AGENT_LOOP_H

#include <stddef.h>

#include "llm_backend.h"
#include "mcp_client.h"   /* McpToolServer for agent_loop_run tool dispatch (S6) */
#include "tool_policy.h"  /* ToolPolicy allowlist for dispatch filtering */

#ifdef __cplusplus
extern "C" {
#endif

/* A single tool call emitted by the model.  id/name/arguments point into the
 * TurnResult's OWN buffers (caller frees via agent_loop_free_turn).  arguments
 * is the JSON arguments string; length-capped at AGENT_ARGS_CAP. */
typedef struct LlmToolCall {
    const char *id;            /* call id (non-empty) */
    const char *name;          /* tool name, e.g. "get_weather" */
    const char *arguments;     /* JSON arguments object as a string */
    size_t      arguments_len;
} LlmToolCall;

/* One message in the conversation.  role is user|assistant|system|tool.
 * content is a plain UTF-8 string of content_len bytes (NUL-terminated at
 * [content_len] for convenience).  tool_call_id is for role=tool (S6);
 * tool_calls/n_tool_calls are for role=assistant (S6) — both empty in S4. */
typedef struct LlmMsg {
    const char *role;
    const char *content;
    size_t      content_len;

    const char *tool_call_id;      /* role=tool (S6) */

    size_t       n_tool_calls;     /* role=assistant (S6) */
    LlmToolCall *tool_calls;
} LlmMsg;

/* The result of one turn.  Buffers are grow buffers owned by the caller.
 * text is the accumulated assistant text (NUL-terminated; may be empty when the
 * turn only emits tool calls).  tool_calls is the array of emitted tool calls.
 * finish_reason is the response.status ("completed", ...) when the backend
 * surfaced one, else empty. */
typedef struct TurnResult {
    char  *text;      size_t text_len;      size_t text_cap;
    char  *finish_reason; size_t finish_reason_len; size_t finish_reason_cap;

    LlmToolCall *tool_calls;
    size_t      n_tool_calls;
    size_t      tool_calls_cap;
} TurnResult;

/* Hard cap on a tool call's accumulated arguments JSON (attacker-shaped —
 * prompt-injection surface). */
#define AGENT_ARGS_CAP (64 * 1024)

/* Run ONE turn: build the OpenAI Responses request JSON from `msgs`
 * (model + stream:true + input array), stream via b->chat_stream, accumulate
 * DELTA_TEXT -> out->text, DELTA_TOOL_CALL -> out->tool_calls, DELTA_FINISH ->
 * out->finish_reason.  `model` is the model name (NULL -> "deepseek-v4-flash";
 * the Backend does not carry the model name).  Returns 0 on success, -1 on
 * backend error / OOM.  On error, *out is left zeroed (caller frees if it
 * initialized it). */
int agent_loop_run_single_turn(const Backend *b, const char *model,
                               const LlmMsg *msgs, size_t n_msgs,
                               TurnResult *out);

/* Free all buffers owned by `out` (text, finish_reason, tool_calls array + each
 * call's id/name/arguments) and zero it.  NULL safe. */
void agent_loop_free_turn(TurnResult *out);

/* Run a multi-turn tool loop (S6).  Maintains a GROWING message list across
 * turns: starts with a copy of the caller `msgs`; each turn runs the existing
 * agent_loop_run_single_turn over the current list.  When a turn emits one or
 * more tool_calls, each is dispatched via mcp_tools_call(tool_srv, ...) and the
 * results are appended to the growing list as an assistant message carrying the
 * turn's text + its tool_calls, followed by one role=tool message
 * (tool_call_id = call.id, content = the tool result) per dispatched call.
 * Then the loop continues to the next turn.  The loop stops when a turn emits 0
 * tool_calls, when max_turns turns have run, or when tool_calls are emitted but
 * tool_srv is NULL (nothing to dispatch).  *out_final is set to the LAST turn's
 * TurnResult (text + any tool_calls) and is owned by the caller (free via
 * agent_loop_free_turn).
 *
 * max_turns must be > 0 (<= 0 -> replaced by runner_max_turns(), the
 * FX_MAX_TURNS default of 1000).  tool_srv may be NULL (no tool dispatch).
 * Returns 0 on success, -1 on backend error / OOM / unsupported dispatch.  On
 * error, *out_final is left zeroed.  On a tool dispatch failure the failing call
 * is recorded as a role=tool message with an error text and the loop continues
 * (the model can react), rather than aborting the whole run. */
int agent_loop_run(const Backend *b, const char *model,
                   const McpToolServer *tool_srv,
                   const LlmMsg *msgs, size_t n_msgs, int max_turns,
                   TurnResult *out_final);

/* Called once for EVERY message appended to the loop's internal growing
 * message list — the seeded copies of the caller `msgs` and every assistant /
 * role=tool message the loop appends across turns.  `m` is a pointer into the
 * loop's OWN list and is valid only for the duration of the call: the callback
 * must copy (deep-copy) anything it wants to keep (S11's transcript callback
 * feeds it to ckpt_append, which deep-copies + length-caps).  `user` is the
 * opaque pointer passed to agent_loop_run_ex. */
typedef void (*agent_loop_msg_cb)(const LlmMsg *m, void *user);

/* agent_loop_run_ex: identical to agent_loop_run (same semantics, same
 * signature minus the trailing callback), except it fires `cb(m, cb_user)`
 * after every message is appended to the internal list (after each seed copy
 * and after each assistant/tool append).  `policy` is the tool allowlist
 * (NULL -> allow-all) enforced BEFORE every mcp_tools_call dispatch: a tool
 * denied by the policy is NOT dispatched — instead a role=tool message with
 * content "(tool disabled)" is appended (so the loop's invariant that every
 * assistant tool_call gets a matching role=tool result holds).  This is the
 * S11 extension that lets an embedding program capture the full transcript
 * WITHOUT depending on agent_loop.c's internals or on checkpoint.h.  `cb` may
 * be NULL (no-op).
 *
 * agent_loop_run is a thin wrapper over this with cb=NULL, so existing callers
 * are unchanged. */
int agent_loop_run_ex(const Backend *b, const char *model,
                      const McpToolServer *tool_srv, const ToolPolicy *policy,
                      const LlmMsg *msgs, size_t n_msgs, int max_turns,
                      TurnResult *out_final, agent_loop_msg_cb cb, void *cb_user);

/* ── per-delta streaming hook (S12) ────────────────────────────────────── */

/* Abort flag the delta callback may set to request a clean stop of the run
 * (e.g. the user pressed quit mid-stream).  For agent_loop_run_delta, the
 * opaque `dc_user` pointer MUST point to a struct whose FIRST member is this
 * int (i.e. castable to DeltaAbort *): the delta callback sets `abort = 1` to
 * request a stop.  When set, the loop stops accumulating the current turn and
 * returns -1; the caller's abort flag remains set so it can distinguish a
 * user-initiated abort from a genuine error. */
typedef struct DeltaAbort {
    int abort;
} DeltaAbort;

/* Called once for EVERY non-DELTA_NONE Delta the loop's sink receives, in
 * order, BEFORE the delta is accumulated into the turn result.  `d` is a
 * pointer into the backend's stream context and is valid ONLY for the duration
 * of the call — the callback must consume it synchronously (the TUI streams
 * text/tool-call fragments live from here).  `user` is the opaque pointer
 * passed to agent_loop_run_delta; for the abort contract it must begin with a
 * DeltaAbort (see above). */
typedef void (*agent_loop_delta_cb)(const Delta *d, void *user);

/* agent_loop_run_delta: identical to agent_loop_run_ex (same semantics —
 * seeds copied + transcript cb fired per appended message + out_final = the
 * last turn), except it ALSO fires `dcb(d, dc_user)` for every non-DELTA_NONE
 * delta, live, before accumulation (the S12 live-streaming hook the TUI
 * needs).  `dcb` may be NULL (no-op).  `cb`/`cb_user` (the transcript hook)
 * and `dcb`/`dc_user` are independent; pass NULL for either to disable it.
 *
 * Abort contract: `dc_user` must begin with a DeltaAbort.  If `dcb` sets its
 * `abort` member to 1, the loop stops accumulating the current turn and
 * returns -1 (the caller reads the flag back to distinguish abort from error).
 *
 * agent_loop_run / agent_loop_run_ex are unchanged thin wrappers (dcb=NULL),
 * so existing callers are byte-identical. */
int agent_loop_run_delta(const Backend *b, const char *model,
                         const McpToolServer *tool_srv, const ToolPolicy *policy,
                         const LlmMsg *msgs, size_t n_msgs, int max_turns,
                         TurnResult *out_final, agent_loop_msg_cb cb, void *cb_user,
                         agent_loop_delta_cb dcb, void *dc_user);

/* agent_loop_run_delta_ex: agent_loop_run_delta plus the loop's OWN END-STATE in
 * *out_exhausted (may be NULL):
 *
 *   1  the loop stopped because it ran out of TURNS while the model still wanted
 *      tool calls: the last allowed turn's tool calls are surfaced in out_final
 *      and NOT dispatched, so the TASK DID NOT FINISH.  This is the ONLY way a
 *      run can end with rc==0 without having produced a final answer, and a
 *      caller that records success must not treat it as one.
 *   0  every other stop (a final text turn with no tool calls, no tool server to
 *      dispatch into, or a backend error with rc != 0).
 *
 * It exists because "rc == 0" is not "the task is complete": the end-of-run
 * `done` marker (src/agent/outcome.c) must not be written for a turn-limited run,
 * or an unfinished task is permanently recorded complete. */
int agent_loop_run_delta_ex(const Backend *b, const char *model,
                            const McpToolServer *tool_srv, const ToolPolicy *policy,
                            const LlmMsg *msgs, size_t n_msgs, int max_turns,
                            TurnResult *out_final, agent_loop_msg_cb cb, void *cb_user,
                            agent_loop_delta_cb dcb, void *dc_user,
                            int *out_exhausted);

#ifdef __cplusplus
}
#endif

#endif /* AGENT_LOOP_H */
