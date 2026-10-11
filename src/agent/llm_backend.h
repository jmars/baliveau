/* src/agent/llm_backend.h — backend interface.
 *
 * The uniform contract every LLM backend adapter (openai_responses, generic,
 * mistral, anthropic) implements, mapping a vendor SSE stream onto a small set
 * of DELTA events consumed by the agent loop.
 *
 * Interface design (the contract is the bullets below):
 *   - chat_stream: build/send a POST to <base_url>/<endpoint>, stream the
 *     read-to-EOF body through the S2 SSE parser, dispatch each event through
 *     parse_event, and forward every non-DELTA_NONE Delta to the sink.
 *   - parse_event: turn one SSE (event_name, data-payload) pair into a Delta.
 *     Because tool-call arguments accumulate across MULTIPLE
 *     response.function_call_arguments.delta events, parse_event is driven on a
 *     PER-STREAM accumulator object (owned by the adapter, created in
 *     chat_stream) so multi-event state survives across calls.
 *
 * Memory-safety (carried over from the L2 rules):
 *   - Delta slices (text/tool_name/tool_call_id/tool_args/finish_reason) point
 *     into the STREAM CONTEXT's bounded, retained buffers.  They are valid only
 *     until the NEXT parse_event call on the same context, and (during
 *     chat_stream) are valid exactly until the synchronous sink call that
 *     follows.  The sink must copy/consume synchronously.
 *   - Tool-call args are attacker-shaped (prompt-injection); the adapter caps
 *     them in a bounded grow buffer (~64 KiB).  NO strcpy/strcat/sprintf on
 *     network bytes.  JSON is ALWAYS parsed with yyjson.
 */
#ifndef LLM_BACKEND_H
#define LLM_BACKEND_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* What kind of Delta an event produced.  DELTA_NONE = event consumed but no
 * user-visible delta (e.g. a status/created event) — nothing to forward. */
typedef enum DeltaType {
    DELTA_NONE = 0,
    DELTA_TEXT,        /* assistant output text fragment */
    DELTA_REASONING,   /* reasoning/chain-of-thought text fragment */
    DELTA_TOOL_CALL,   /* a COMPLETE tool call (name + call_id + full args) */
    DELTA_FINISH,      /* the stream is done (response.completed or EOF) */
    DELTA_ERROR        /* a terminal error was surfaced */
} DeltaType;

/* A single stream event.  Pointer fields reference the stream context's
 * retained buffers (see header note); *_len is the length of the slice.  A
 * slice is NUL-terminated at [len] for convenience but `len` is authoritative. */
typedef struct Delta {
    DeltaType type;

    /* DELTA_TEXT / DELTA_REASONING. */
    const char *text;     size_t text_len;

    /* DELTA_TOOL_CALL. */
    const char *tool_name;     size_t tool_name_len;
    const char *tool_call_id;  size_t tool_call_id_len;
    const char *tool_args;     size_t tool_args_len;

    /* DELTA_FINISH. */
    const char *finish_reason; size_t finish_reason_len;
} Delta;

/* Sink callback: receives every non-DELTA_NONE Delta.  `user` is the opaque
 * pointer threaded through chat_stream.  Must consume `d` synchronously. */
typedef void (*sse_sink_cb)(const Delta *d, void *user);

/* Forward decl so the fn-pointer fields below can use the `Backend` typedef. */
typedef struct Backend Backend;

/* The REQUEST serialization format a backend speaks.  The agent loop
 * (agent_loop.c) builds its request JSON to match: RESPONSES -> the OpenAI
 * Responses `input[]` item shape; CHAT_COMPLETIONS -> OpenAI chat-completions
 * `messages[]` (also Mistral, which reuses generic's vocabulary); ANTHROPIC ->
 * Anthropic Messages `messages[]` + top-level `system`.  RESPONSES is 0 so a
 * zero-initialized Backend (the mocks in tests) defaults to it. */
typedef enum BackendFormat {
    RESPONSES = 0,
    CHAT_COMPLETIONS,
    ANTHROPIC
} BackendFormat;

/* A backend adapter.  base_url is "http://host[:port]" or "https://host".
 * chat_stream/parse_event are the adapter's entry points; impl is adapter
 * private state (may be NULL).  format selects the request serializer the
 * agent loop builds (see BackendFormat); api_key is the borrowed API key the
 * adapter puts in its auth header (NULL -> no auth header), resolved by
 * backend_build() from the provider's api_key_env_var. */
struct Backend {
    const char *base_url;
    int  (*chat_stream)(const Backend *b, const char *req_json, size_t req_len,
                        sse_sink_cb sink, void *user);
    int  (*parse_event)(void *stream_ctx, const char *event_name,
                        const char *data, size_t data_len, Delta *out);
    void *impl;
    BackendFormat format;
    const char *api_key;
};

/* ── OpenAI Responses backend (S3) ─────────────────────────────────────── */

/* chat_stream: POST req_json to <base_url>/v1/responses (Accept:
 * text/event-stream), stream the SSE body through the S2 parser, dispatch via
 * parse_event, forward deltas to sink, end on response.completed (DELTA_FINISH)
 * or read-to-EOF.  Returns 0 on a clean stream, -1 on any error.  `b->base_url`
 * must be set; `b->parse_event` is used for dispatch. */
int openai_responses_chat_stream(const Backend *b, const char *req_json,
                                 size_t req_len, sse_sink_cb sink, void *user);

/* parse_event for the Responses vocabulary.  `stream_ctx` MUST come from
 * openai_responses_create_stream (it carries the tool-call accumulator).  Fills
 * *out (type = DELTA_NONE when the event yields nothing to forward).  Returns
 * 0 on success, -1 on malformed data / OOM / oversize. */
int openai_responses_parse_event(void *stream_ctx, const char *event_name,
                                 const char *data, size_t data_len, Delta *out);

/* Per-stream accumulator object (opaque): owns the current tool-call
 * (name/call_id/args) and a scratch buffer for delta slices.  create_stream
 * returns NULL on OOM. */
void *openai_responses_create_stream(void);
void  openai_responses_free_stream(void *ctx);

/* A ready-to-use Backend (base_url = the local router).  Adapters can be
 * re-pointed at a different base_url by building a Backend struct directly. */
const Backend *openai_responses_backend(void);

/* ── Generic OpenAI-compatible chat-completions backend (S8) ───────────── */

/* chat_stream: POST req_json to <base_url>/v1/chat/completions, stream the SSE
 * body (bare `data:` JSON with choices[0].delta.*), dispatch via
 * generic_parse_event.  Reused verbatim by mistral (same vocabulary; only the
 * base_url differs).  When b->api_key is set, emits `Authorization: Bearer
 * <key>`. */
int generic_chat_stream(const Backend *b, const char *req_json, size_t req_len,
                        sse_sink_cb sink, void *user);
int generic_parse_event(void *stream_ctx, const char *event_name,
                        const char *data, size_t data_len, Delta *out);
void *generic_create_stream(void);
void  generic_free_stream(void *ctx);
const Backend *generic_backend(void);

/* Mistral reuses generic's chat_stream/parse_event; only the backend accessor
 * differs (base_url = https://api.mistral.ai). */
const Backend *mistral_backend(void);

/* ── Anthropic Messages backend (S8) ───────────────────────────────────── */

/* chat_stream: POST req_json to <base_url>/v1/messages (event: + data: SSE;
 * ends on message_stop, no [DONE]).  Emits `anthropic-version: 2023-06-01`
 * always and `x-api-key: <key>` when b->api_key is set. */
int anthropic_chat_stream(const Backend *b, const char *req_json, size_t req_len,
                          sse_sink_cb sink, void *user);
int anthropic_parse_event(void *stream_ctx, const char *event_name,
                          const char *data, size_t data_len, Delta *out);
void *anthropic_create_stream(void);
void  anthropic_free_stream(void *ctx);
const Backend *anthropic_backend(void);

/* ── backend factory (provider routing) ────────────────────────────────── */

/* Build a caller-owned Backend from a provider spec.  `type` selects the
 * adapter: "openai_responses" | "generic" | "mistral" | "anthropic".  Sets
 * base_url (borrowed — the caller's config owns the string for the process
 * lifetime), format, chat_stream/parse_event, and resolves api_key =
 * getenv(api_key_env_var) when the env var name is non-empty (borrowed;
 * process-lifetime).  Unknown `type` -> returns -1 and leaves `out` untouched
 * (the caller fail-opens to openai_responses_backend()).  Returns 0 on
 * success. */
int backend_build(Backend *out, const char *type, const char *base_url,
                  const char *api_key_env_var);

#ifdef __cplusplus
}
#endif

#endif /* LLM_BACKEND_H */
