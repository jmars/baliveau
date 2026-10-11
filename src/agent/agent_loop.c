/* src/agent/agent_loop.c — tool-call TURN loop.
 *
 * Single-turn iteration over the llm_backend.h interface: build the request
 * JSON from a message list (format-aware per b->format — OpenAI Responses,
 * chat-completions, or Anthropic Messages), stream via b->chat_stream, and
 * accumulate the emitted deltas (text / tool_calls / finish_reason) into a
 * caller-owned TurnResult.  NO tool dispatch yet (S6).
 *
 * The request JSON is built with yyjson_mut (never hand-concatenated network
 * JSON).  Delta slices are valid only for the synchronous sink call, so the
 * sink memcpy's every slice into the loop's OWN grow buffers immediately.
 * Tool-call args are attacker-shaped and length-capped (AGENT_ARGS_CAP, 64 KiB).
 * Every malloc/realloc is checked; failures surface as return -1 (or a recorded
 * sink error, folded into the return).  No strcpy/strcat/sprintf on network
 * bytes.  See agent_loop.h for the message / TurnResult model.
 */
#include "agent_loop.h"

#include "yyjson.h"
#include "runner.h"   /* runner_max_turns() (S6 default max-turns bound) */
#include "tool_policy.h" /* tool_policy_allowed() (dispatch filtering) */

#include <stdlib.h>
#include <string.h>

#define DEFAULT_MODEL "deepseek-v4-flash"

/* Text / finish_reason accumulator cap (generous; bounds unbounded text). */
#define AGENT_TEXT_CAP (4 * 1024 * 1024)

/* Bounded grow-append (the S2 grow_append_cap idiom, copied locally — do NOT
 * modify sse.c).  Never lets *len exceed maxcap; keeps a NUL at [*len]. */
static int grow_append(char **buf, size_t *len, size_t *cap,
                       const char *src, size_t n, size_t maxcap) {
    if (*len > maxcap || n > maxcap - *len) return -1; /* oversize: DoS guard */
    if (*len + n + 1 > *cap) {
        size_t nc = *cap ? *cap * 2 : 64;
        if (nc < *len + n + 1) nc = *len + n + 1;
        if (nc > maxcap + 1) nc = maxcap + 1;
        char *nd = (char *)realloc(*buf, nc);
        if (!nd) return -1;
        *buf = nd;
        *cap = nc;
    }
    memcpy(*buf + *len, src, n);
    *len += n;
    (*buf)[*len] = '\0';
    return 0;
}

/* ── request JSON builders (format-aware) ─────────────────────────────── */

/* Build the OpenAI RESPONSES request JSON from the message list, mapping each
 * message to Responses ITEMS per the VERIFIED wire format (the S4-reviewer
 * rework — see handoff-c-runtime-l2-s6-ctx):
 *   { "model": <model>, "stream": true,
 *     "input": [
 *       {role, content}                        // plain user/assistant/system
 *       {role:"assistant", content}            // an assistant msg carrying
 *         then per tool_call:                  //   its tool_calls, followed by
 *           {"type":"function_call", call_id, name, arguments}   // one each
 *       {"type":"function_call_output",        // a role=tool message
 *        call_id:tool_call_id, output:content}
 *     ] }
 * A conversation after a tool call must carry the assistant's function_call AND
 * the tool result as SEPARATE ITEMS (NOT Chat-Completions role=tool messages).
 * Returns a malloc'd NUL-terminated string (free with free()), or NULL on OOM.
 * `model` may be NULL (defaulted).  tools array omitted (S6 sends none; the
 * router injects tools per its own config).  yyjson_mut is used exclusively;
 * attacker-shaped fields (id/name/arguments/output) are escaped via
 * yyjson_mut_obj_add_strncpy, never hand-interpolated. */
static char *build_responses_request(const char *model,
                                     const LlmMsg *msgs, size_t n_msgs,
                                     size_t *req_len) {
    yyjson_mut_doc *doc = yyjson_mut_doc_new(NULL);
    if (!doc) return NULL;
    yyjson_mut_val *root = yyjson_mut_obj(doc);
    if (!root) { yyjson_mut_doc_free(doc); return NULL; }
    yyjson_mut_doc_set_root(doc, root);

    yyjson_mut_obj_add_strcpy(doc, root, "model",
                              model ? model : DEFAULT_MODEL);
    yyjson_mut_obj_add_bool(doc, root, "stream", true);

    yyjson_mut_val *input = yyjson_mut_obj_add_arr(doc, root, "input");
    if (!input) { yyjson_mut_doc_free(doc); return NULL; }

    for (size_t i = 0; i < n_msgs; i++) {
        const LlmMsg *m = &msgs[i];

        if (m->role && strcmp(m->role, "tool") == 0) {
            /* role=tool -> a function_call_output item.  Requires the call id. */
            if (!m->tool_call_id) continue; /* skip a malformed tool msg */
            yyjson_mut_val *o = yyjson_mut_obj(doc);
            if (!o) goto oom;
            yyjson_mut_obj_add_strcpy(doc, o, "type", "function_call_output");
            /* call_id is attacker-shaped (from the model) -> escape. */
            yyjson_mut_obj_add_strncpy(doc, o, "call_id", m->tool_call_id,
                                       strlen(m->tool_call_id));
            yyjson_mut_obj_add_strncpy(doc, o, "output",
                                       m->content ? m->content : "",
                                       m->content ? m->content_len : 0);
            if (!yyjson_mut_arr_append(input, o)) goto oom;
            continue;
        }

        if (m->n_tool_calls > 0 && m->tool_calls) {
            /* An assistant message carrying tool_calls: its {role, content}
             * item, then one function_call item per tool_call. */
            yyjson_mut_val *o = yyjson_mut_obj(doc);
            if (!o) goto oom;
            yyjson_mut_obj_add_strcpy(doc, o, "role",
                                      m->role ? m->role : "assistant");
            yyjson_mut_obj_add_strncpy(doc, o, "content",
                                       m->content ? m->content : "",
                                       m->content ? m->content_len : 0);
            if (!yyjson_mut_arr_append(input, o)) goto oom;
            for (size_t j = 0; j < m->n_tool_calls; j++) {
                const LlmToolCall *tc = &m->tool_calls[j];
                yyjson_mut_val *fc = yyjson_mut_obj(doc);
                if (!fc) goto oom;
                yyjson_mut_obj_add_strcpy(doc, fc, "type", "function_call");
                /* id/name/arguments are attacker-shaped (model output) -> escape. */
                yyjson_mut_obj_add_strncpy(doc, fc, "call_id",
                                           tc->id ? tc->id : "",
                                           tc->id ? strlen(tc->id) : 0);
                yyjson_mut_obj_add_strncpy(doc, fc, "name",
                                           tc->name ? tc->name : "",
                                           tc->name ? strlen(tc->name) : 0);
                yyjson_mut_obj_add_strncpy(doc, fc, "arguments",
                                           tc->arguments ? tc->arguments : "{}",
                                           tc->arguments ? tc->arguments_len : 2);
                if (!yyjson_mut_arr_append(input, fc)) goto oom;
            }
            continue;
        }

        /* Plain role user/assistant/system with content. */
        yyjson_mut_val *o = yyjson_mut_obj(doc);
        if (!o) goto oom;
        yyjson_mut_obj_add_strcpy(doc, o, "role",
                                  m->role ? m->role : "user");
        if (m->content) {
            yyjson_mut_obj_add_strncpy(doc, o, "content",
                                       m->content, m->content_len);
        }
        if (!yyjson_mut_arr_append(input, o)) goto oom;
    }

    char *json = yyjson_mut_write(doc, 0, req_len);
    yyjson_mut_doc_free(doc);
    return json;

oom:
    yyjson_mut_doc_free(doc);
    return NULL;
}

/* Build the OpenAI CHAT-COMPLETIONS request JSON:
 *   { model, stream:true, messages:[...] } where
 *   role=tool            -> {role:"tool", tool_call_id, content}
 *   assistant w/ tool_calls -> {role:"assistant", content,
 *                               tool_calls:[{id, type:"function",
 *                                            function:{name, arguments}}]}
 *   everything else      -> {role, content}
 * Same escaping discipline as the Responses builder: attacker-shaped fields
 * (ids/names/arguments/content) are added via yyjson_mut_obj_add_strncpy.
 * Returns a malloc'd NUL-terminated string (free with free()), or NULL on OOM. */
static char *build_chat_completions_request(const char *model,
                                            const LlmMsg *msgs, size_t n_msgs,
                                            size_t *req_len) {
    yyjson_mut_doc *doc = yyjson_mut_doc_new(NULL);
    if (!doc) return NULL;
    yyjson_mut_val *root = yyjson_mut_obj(doc);
    if (!root) { yyjson_mut_doc_free(doc); return NULL; }
    yyjson_mut_doc_set_root(doc, root);

    yyjson_mut_obj_add_strcpy(doc, root, "model", model ? model : DEFAULT_MODEL);
    yyjson_mut_obj_add_bool(doc, root, "stream", true);

    yyjson_mut_val *messages = yyjson_mut_obj_add_arr(doc, root, "messages");
    if (!messages) { yyjson_mut_doc_free(doc); return NULL; }

    for (size_t i = 0; i < n_msgs; i++) {
        const LlmMsg *m = &msgs[i];

        if (m->role && strcmp(m->role, "tool") == 0) {
            /* role=tool -> a chat-completions tool result message.  Requires
             * the call id to pair it with the assistant's tool_call. */
            if (!m->tool_call_id) continue; /* skip a malformed tool msg */
            yyjson_mut_val *o = yyjson_mut_obj(doc);
            if (!o) goto oom;
            yyjson_mut_obj_add_strcpy(doc, o, "role", "tool");
            yyjson_mut_obj_add_strncpy(doc, o, "tool_call_id", m->tool_call_id,
                                       strlen(m->tool_call_id));
            yyjson_mut_obj_add_strncpy(doc, o, "content",
                                       m->content ? m->content : "",
                                       m->content ? m->content_len : 0);
            if (!yyjson_mut_arr_append(messages, o)) goto oom;
            continue;
        }

        if (m->n_tool_calls > 0 && m->tool_calls) {
            /* An assistant message carrying tool_calls: one message whose
             * content + a tool_calls[] array (each with its function block). */
            yyjson_mut_val *o = yyjson_mut_obj(doc);
            if (!o) goto oom;
            yyjson_mut_obj_add_strcpy(doc, o, "role",
                                      m->role ? m->role : "assistant");
            yyjson_mut_obj_add_strncpy(doc, o, "content",
                                       m->content ? m->content : "",
                                       m->content ? m->content_len : 0);
            yyjson_mut_val *tcs = yyjson_mut_obj_add_arr(doc, o, "tool_calls");
            if (!tcs) goto oom;
            for (size_t j = 0; j < m->n_tool_calls; j++) {
                const LlmToolCall *tc = &m->tool_calls[j];
                yyjson_mut_val *tco = yyjson_mut_obj(doc);
                if (!tco) goto oom;
                yyjson_mut_obj_add_strncpy(doc, tco, "id", tc->id ? tc->id : "",
                                           tc->id ? strlen(tc->id) : 0);
                yyjson_mut_obj_add_strcpy(doc, tco, "type", "function");
                yyjson_mut_val *fn = yyjson_mut_obj(doc);
                if (!fn) goto oom;
                yyjson_mut_obj_add_strncpy(doc, fn, "name",
                                           tc->name ? tc->name : "",
                                           tc->name ? strlen(tc->name) : 0);
                yyjson_mut_obj_add_strncpy(doc, fn, "arguments",
                                           tc->arguments ? tc->arguments : "{}",
                                           tc->arguments ? tc->arguments_len : 2);
                yyjson_mut_obj_add_val(doc, tco, "function", fn);
                if (!yyjson_mut_arr_append(tcs, tco)) goto oom;
            }
            if (!yyjson_mut_arr_append(messages, o)) goto oom;
            continue;
        }

        /* Plain role user/assistant with content. */
        yyjson_mut_val *o = yyjson_mut_obj(doc);
        if (!o) goto oom;
        yyjson_mut_obj_add_strcpy(doc, o, "role", m->role ? m->role : "user");
        if (m->content) {
            yyjson_mut_obj_add_strncpy(doc, o, "content", m->content, m->content_len);
        }
        if (!yyjson_mut_arr_append(messages, o)) goto oom;
    }

    char *json = yyjson_mut_write(doc, 0, req_len);
    yyjson_mut_doc_free(doc);
    return json;

oom:
    yyjson_mut_doc_free(doc);
    return NULL;
}

/* Hardcoded default for Anthropic's REQUIRED max_tokens field (Anthropic has no
 * default; a value is mandatory).  A real provider may cap this lower. */
#define ANTHROPIC_MAX_TOKENS 4096

/* Embed a tool_use block's `input` object for the Anthropic request.  The
 * accumulated arguments are attacker-shaped JSON (from the model); Anthropic
 * requires an OBJECT (not a string) here.  Parse the arguments and deep-copy
 * the object into the mutable doc; fall back to an empty object when the
 * arguments do not parse as a JSON object. */
static void add_anthropic_input(yyjson_mut_doc *doc, yyjson_mut_val *tco,
                                const char *args, size_t args_len) {
    yyjson_mut_val *input = NULL;
    if (args && args_len) {
        yyjson_doc *adoc = yyjson_read(args, args_len, 0);
        if (adoc) {
            yyjson_val *aval = yyjson_doc_get_root(adoc);
            if (aval && yyjson_is_obj(aval))
                input = yyjson_val_mut_copy(doc, aval);
            yyjson_doc_free(adoc);
        }
    }
    if (!input) input = yyjson_mut_obj(doc); /* malformed args -> empty input */
    yyjson_mut_obj_add_val(doc, tco, "input", input);
}

/* Build the Anthropic MESSAGES request JSON:
 *   { model, stream:true, max_tokens, [system], messages:[...] }
 * Anthropic has no system message role: role=system content is pulled out into
 * the top-level `system` field (joined with '\n' when several).  Messages map
 *   role=tool      -> a USER message whose content is a tool_result content
 *                     block {type:"tool_result", tool_use_id, content}
 *   assistant w/ tool_calls -> an assistant message whose content is an ARRAY
 *                     of content blocks: a {type:"text",text} block (when the
 *                     message carries text) then one {type:"tool_use", id,
 *                     name, input} block per tool call.
 *   everything else -> {role, content} (string content).
 * Returns a malloc'd NUL-terminated string (free with free()), or NULL on OOM. */
static char *build_anthropic_request(const char *model,
                                     const LlmMsg *msgs, size_t n_msgs,
                                     size_t *req_len) {
    yyjson_mut_doc *doc = yyjson_mut_doc_new(NULL);
    if (!doc) return NULL;
    yyjson_mut_val *root = yyjson_mut_obj(doc);
    if (!root) { yyjson_mut_doc_free(doc); return NULL; }
    yyjson_mut_doc_set_root(doc, root);

    yyjson_mut_obj_add_strcpy(doc, root, "model", model ? model : DEFAULT_MODEL);
    yyjson_mut_obj_add_bool(doc, root, "stream", true);
    yyjson_mut_obj_add_uint(doc, root, "max_tokens", ANTHROPIC_MAX_TOKENS);

    /* Collect role=system content into the top-level `system` field. */
    size_t sys_len = 0;
    char *system = NULL;
    for (size_t i = 0; i < n_msgs; i++) {
        const LlmMsg *m = &msgs[i];
        if (m->role && strcmp(m->role, "system") == 0 &&
            m->content && m->content_len) {
            size_t add = m->content_len + (sys_len ? 1 : 0);
            char *ns = (char *)realloc(system, sys_len + add + 1);
            if (!ns) { free(system); yyjson_mut_doc_free(doc); return NULL; }
            system = ns;
            if (sys_len) system[sys_len++] = '\n';
            memcpy(system + sys_len, m->content, m->content_len);
            sys_len += m->content_len;
            system[sys_len] = '\0';
        }
    }
    if (system) {
        yyjson_mut_obj_add_strncpy(doc, root, "system", system, sys_len);
        free(system);
    }

    yyjson_mut_val *messages = yyjson_mut_obj_add_arr(doc, root, "messages");
    if (!messages) { yyjson_mut_doc_free(doc); return NULL; }

    for (size_t i = 0; i < n_msgs; i++) {
        const LlmMsg *m = &msgs[i];

        if (m->role && strcmp(m->role, "system") == 0) continue; /* top-level */

        if (m->role && strcmp(m->role, "tool") == 0) {
            /* role=tool -> a USER message holding a tool_result content block. */
            if (!m->tool_call_id) continue; /* skip a malformed tool msg */
            yyjson_mut_val *o = yyjson_mut_obj(doc);
            if (!o) goto oom;
            yyjson_mut_obj_add_strcpy(doc, o, "role", "user");
            yyjson_mut_val *blocks = yyjson_mut_arr(doc);
            if (!blocks) goto oom;
            yyjson_mut_val *tr = yyjson_mut_obj(doc);
            if (!tr) goto oom;
            yyjson_mut_obj_add_strcpy(doc, tr, "type", "tool_result");
            yyjson_mut_obj_add_strncpy(doc, tr, "tool_use_id", m->tool_call_id,
                                       strlen(m->tool_call_id));
            yyjson_mut_obj_add_strncpy(doc, tr, "content",
                                       m->content ? m->content : "",
                                       m->content ? m->content_len : 0);
            if (!yyjson_mut_arr_append(blocks, tr)) goto oom;
            yyjson_mut_obj_add_val(doc, o, "content", blocks);
            if (!yyjson_mut_arr_append(messages, o)) goto oom;
            continue;
        }

        if (m->n_tool_calls > 0 && m->tool_calls) {
            /* An assistant message carrying tool_calls: a content-block array
             * with an optional text block then one tool_use block per call. */
            yyjson_mut_val *o = yyjson_mut_obj(doc);
            if (!o) goto oom;
            yyjson_mut_obj_add_strcpy(doc, o, "role",
                                      m->role ? m->role : "assistant");
            yyjson_mut_val *blocks = yyjson_mut_arr(doc);
            if (!blocks) goto oom;
            if (m->content && m->content_len) {
                yyjson_mut_val *tb = yyjson_mut_obj(doc);
                if (!tb) goto oom;
                yyjson_mut_obj_add_strcpy(doc, tb, "type", "text");
                yyjson_mut_obj_add_strncpy(doc, tb, "text", m->content,
                                           m->content_len);
                if (!yyjson_mut_arr_append(blocks, tb)) goto oom;
            }
            for (size_t j = 0; j < m->n_tool_calls; j++) {
                const LlmToolCall *tc = &m->tool_calls[j];
                yyjson_mut_val *tu = yyjson_mut_obj(doc);
                if (!tu) goto oom;
                yyjson_mut_obj_add_strcpy(doc, tu, "type", "tool_use");
                yyjson_mut_obj_add_strncpy(doc, tu, "id", tc->id ? tc->id : "",
                                           tc->id ? strlen(tc->id) : 0);
                yyjson_mut_obj_add_strncpy(doc, tu, "name",
                                           tc->name ? tc->name : "",
                                           tc->name ? strlen(tc->name) : 0);
                add_anthropic_input(doc, tu, tc->arguments, tc->arguments_len);
                if (!yyjson_mut_arr_append(blocks, tu)) goto oom;
            }
            yyjson_mut_obj_add_val(doc, o, "content", blocks);
            if (!yyjson_mut_arr_append(messages, o)) goto oom;
            continue;
        }

        /* Plain role user/assistant with string content. */
        yyjson_mut_val *o = yyjson_mut_obj(doc);
        if (!o) goto oom;
        yyjson_mut_obj_add_strcpy(doc, o, "role", m->role ? m->role : "user");
        if (m->content) {
            yyjson_mut_obj_add_strncpy(doc, o, "content", m->content, m->content_len);
        }
        if (!yyjson_mut_arr_append(messages, o)) goto oom;
    }

    char *json = yyjson_mut_write(doc, 0, req_len);
    yyjson_mut_doc_free(doc);
    return json;

oom:
    yyjson_mut_doc_free(doc);
    return NULL;
}

/* Dispatch the request build to the serializer matching the backend's format.
 * RESPONSES is the default (format 0); an unknown/garbage format fails safe to
 * the Responses builder. */
static char *build_request_json(BackendFormat format, const char *model,
                                const LlmMsg *msgs, size_t n_msgs,
                                size_t *req_len) {
    switch (format) {
    case CHAT_COMPLETIONS:
        return build_chat_completions_request(model, msgs, n_msgs, req_len);
    case ANTHROPIC:
        return build_anthropic_request(model, msgs, n_msgs, req_len);
    case RESPONSES:
    default:
        return build_responses_request(model, msgs, n_msgs, req_len);
    }
}

/* ── delta sink / accumulator ───────────────────────────────────────────── */

/* Sink user context: the TurnResult being filled + an error flag + the S12
 * per-delta streaming hook (delta_cb/delta_user; may be NULL/disabled). */
typedef struct {
    TurnResult *out;
    int err;   /* set when any grow/copy fails (OOM / oversize) / abort requested */
    agent_loop_delta_cb delta_cb;
    void *delta_user;
} SinkCtx;

/* Append a new LlmToolCall to out->tool_calls, copying each delta slice into
 * buffers owned by the TurnResult.  Returns 0 / -1. */
static int append_tool_call(TurnResult *out, const Delta *d) {
    if (out->n_tool_calls >= out->tool_calls_cap) {
        size_t nc = out->tool_calls_cap ? out->tool_calls_cap * 2 : 4;
        LlmToolCall *nd = (LlmToolCall *)realloc(out->tool_calls,
                                                 nc * sizeof(*nd));
        if (!nd) return -1;
        out->tool_calls = nd;
        out->tool_calls_cap = nc;
    }
    LlmToolCall *tc = &out->tool_calls[out->n_tool_calls];
    memset(tc, 0, sizeof *tc);

    char *id = NULL, *name = NULL, *args = NULL;
    size_t id_len = 0, id_cap = 0, name_len = 0, name_cap = 0;
    size_t args_len = 0, args_cap = 0;

    if (d->tool_call_id && grow_append(&id, &id_len, &id_cap,
                                       d->tool_call_id, d->tool_call_id_len,
                                       AGENT_ARGS_CAP) != 0) goto oom;
    if (d->tool_name && grow_append(&name, &name_len, &name_cap,
                                    d->tool_name, d->tool_name_len,
                                    AGENT_ARGS_CAP) != 0) goto oom;
    if (d->tool_args && grow_append(&args, &args_len, &args_cap,
                                    d->tool_args, d->tool_args_len,
                                    AGENT_ARGS_CAP) != 0) goto oom;

    tc->id = id; tc->name = name;
    tc->arguments = args; tc->arguments_len = args_len;
    out->n_tool_calls++;
    return 0;

oom:
    free(id); free(name); free(args);
    return -1;
}

/* The chat_stream sink.  MUST copy every slice synchronously (deltas are only
 * valid for this call).  Errors are recorded in SinkCtx.err and folded into the
 * run_single_turn return. */
static void loop_sink(const Delta *d, void *user) {
    SinkCtx *sc = (SinkCtx *)user;
    if (sc->err) return;

    /* S12 per-delta streaming hook: forward FIRST (so the TUI renders live),
     * then accumulate.  The delta cb may request a clean abort by setting the
     * abort int at the head of its user struct (see agent_loop.h DeltaAbort);
     * if so, stop accumulating the current turn. */
    if (sc->delta_cb) {
        sc->delta_cb(d, sc->delta_user);
        if (sc->delta_user && ((DeltaAbort *)sc->delta_user)->abort) {
            sc->err = 1;
            return;
        }
    }

    switch (d->type) {
    case DELTA_TEXT:
        if (d->text && d->text_len &&
            grow_append(&sc->out->text, &sc->out->text_len, &sc->out->text_cap,
                        d->text, d->text_len, AGENT_TEXT_CAP) != 0) {
            sc->err = 1;
        }
        break;
    case DELTA_TOOL_CALL:
        if (append_tool_call(sc->out, d) != 0) sc->err = 1;
        break;
    case DELTA_FINISH:
        if (d->finish_reason && d->finish_reason_len &&
            grow_append(&sc->out->finish_reason, &sc->out->finish_reason_len,
                        &sc->out->finish_reason_cap,
                        d->finish_reason, d->finish_reason_len,
                        AGENT_TEXT_CAP) != 0) {
            sc->err = 1;
        }
        break;
    default:
        /* DELTA_NONE / DELTA_REASONING / DELTA_ERROR: not part of the S4
         * accumulated result.  DELTA_ERROR is a terminal error — surface it. */
        if (d->type == DELTA_ERROR) sc->err = 1;
        break;
    }
}

/* ── single-turn entry ──────────────────────────────────────────────────── */

/* The real single-turn body.  `dcb`/`dc_user` thread the S12 per-delta hook
 * into the SinkCtx; NULL disables it (agent_loop_run_single_turn's behavior). */
static int run_single_turn_delta(const Backend *b, const char *model,
                                 const LlmMsg *msgs, size_t n_msgs,
                                 TurnResult *out,
                                 agent_loop_delta_cb dcb, void *dc_user) {
    if (!out) return -1;
    memset(out, 0, sizeof *out); /* on any error, *out is left zeroed */
    if (!b || !b->chat_stream) return -1;

    size_t req_len = 0;
    char *req = build_request_json(b->format, model, msgs, n_msgs, &req_len);
    if (!req) return -1;

    SinkCtx sc = { .out = out, .err = 0, .delta_cb = dcb, .delta_user = dc_user };
    int rc = b->chat_stream(b, req, req_len, loop_sink, &sc);
    free(req);

    if (rc != 0 || sc.err) {
        agent_loop_free_turn(out);
        return -1;
    }
    return 0;
}

int agent_loop_run_single_turn(const Backend *b, const char *model,
                               const LlmMsg *msgs, size_t n_msgs,
                               TurnResult *out) {
    /* Thin wrapper: single turn with no delta hook. */
    return run_single_turn_delta(b, model, msgs, n_msgs, out, NULL, NULL);
}

void agent_loop_free_turn(TurnResult *out) {
    if (!out) return;
    free(out->text);
    free(out->finish_reason);
    for (size_t i = 0; i < out->n_tool_calls; i++) {
        free((void *)out->tool_calls[i].id);
        free((void *)out->tool_calls[i].name);
        free((void *)out->tool_calls[i].arguments);
    }
    free(out->tool_calls);
    memset(out, 0, sizeof *out);
}

/* ── growing message list (S6) ──────────────────────────────────────────── */

/* A grow array of OWNED LlmMsg copies.  Each message's mutable buffers
 * (content, tool_call_id, tool_calls + each call's id/name/arguments) are
 * malloc'd by the list and freed via msglist_free.  role points at a static
 * literal ("assistant"/"tool") or the caller's borrowed string for seeded
 * messages — never freed. */
typedef struct {
    LlmMsg *msgs;
    size_t n;
    size_t cap;
} MsgList;

/* Duplicate a byte slice as a NUL-terminated malloc'd string ("" when len 0). */
static char *dup_n(const char *s, size_t len) {
    char *p = (char *)malloc(len + 1);
    if (!p) return NULL;
    if (len) memcpy(p, s, len);
    p[len] = '\0';
    return p;
}

/* Deep-copy ONE tool call's attacker-shaped fields (id/name/arguments) into
 * freshly malloc'd buffers.  Returns 0 / -1 (OOM), leaving *dst zeroed on
 * failure. */
static int copy_tool_call(LlmToolCall *dst, const LlmToolCall *src) {
    memset(dst, 0, sizeof *dst);
    if (src->id) {
        dst->id = dup_n(src->id, strlen(src->id));
        if (!dst->id) return -1;
    }
    if (src->name) {
        dst->name = dup_n(src->name, strlen(src->name));
        if (!dst->name) { free((void *)dst->id); dst->id = NULL; return -1; }
    }
    if (src->arguments) {
        dst->arguments = dup_n(src->arguments, src->arguments_len);
        if (!dst->arguments) {
            free((void *)dst->id); free((void *)dst->name);
            dst->id = NULL; dst->name = NULL;
            return -1;
        }
        dst->arguments_len = src->arguments_len;
    }
    return 0;
}

/* Free one message's owned buffers (content, tool_call_id, tool_calls + each
 * call's fields) and zero the slot.  Does NOT free the slot itself. */
static void msg_free_fields(LlmMsg *m) {
    free((void *)m->content);
    free((void *)m->tool_call_id);
    for (size_t i = 0; i < m->n_tool_calls; i++) {
        free((void *)m->tool_calls[i].id);
        free((void *)m->tool_calls[i].name);
        free((void *)m->tool_calls[i].arguments);
    }
    free(m->tool_calls);
    memset(m, 0, sizeof *m);
}

/* Transfer ownership of a fully-built owned message into the list.  On success
 * *m is zeroed (ownership moved); on failure *m is left intact (caller frees). */
static int msglist_append_owned(MsgList *ml, LlmMsg *m) {
    if (ml->n >= ml->cap) {
        size_t nc = ml->cap ? ml->cap * 2 : 8;
        LlmMsg *nd = (LlmMsg *)realloc(ml->msgs, nc * sizeof(*nd));
        if (!nd) return -1;
        ml->msgs = nd;
        ml->cap = nc;
    }
    ml->msgs[ml->n++] = *m;
    memset(m, 0, sizeof *m); /* ownership transferred */
    return 0;
}

/* Deep-copy a caller message into the list (used to seed the growing list). */
static int msglist_append_copy(MsgList *ml, const LlmMsg *src) {
    LlmMsg m;
    memset(&m, 0, sizeof m);
    m.role = src->role; /* borrowed */
    if (src->content) {
        m.content = dup_n(src->content, src->content_len);
        if (!m.content) return -1;
        m.content_len = src->content_len;
    }
    if (src->tool_call_id) {
        m.tool_call_id = dup_n(src->tool_call_id, strlen(src->tool_call_id));
        if (!m.tool_call_id) { free((void *)m.content); return -1; }
    }
    if (src->n_tool_calls > 0 && src->tool_calls) {
        m.tool_calls = (LlmToolCall *)calloc(src->n_tool_calls, sizeof(*m.tool_calls));
        if (!m.tool_calls) {
            free((void *)m.content); free((void *)m.tool_call_id);
            return -1;
        }
        for (size_t i = 0; i < src->n_tool_calls; i++) {
            if (copy_tool_call(&m.tool_calls[i], &src->tool_calls[i]) != 0) {
                m.n_tool_calls = i;
                msg_free_fields(&m);
                return -1;
            }
        }
        m.n_tool_calls = src->n_tool_calls;
    }
    if (msglist_append_owned(ml, &m) != 0) {
        msg_free_fields(&m);
        return -1;
    }
    return 0;
}

static void msglist_free(MsgList *ml) {
    if (!ml) return;
    for (size_t i = 0; i < ml->n; i++) msg_free_fields(&ml->msgs[i]);
    free(ml->msgs);
    ml->msgs = NULL;
    ml->n = ml->cap = 0;
}

/* Set n tool calls on an owned message, deep-copying each.  Returns 0 / -1. */
static int msg_set_tool_calls(LlmMsg *m, const LlmToolCall *calls, size_t n) {
    m->tool_calls = (LlmToolCall *)calloc(n, sizeof(*m->tool_calls));
    if (!m->tool_calls) return -1;
    for (size_t i = 0; i < n; i++) {
        if (copy_tool_call(&m->tool_calls[i], &calls[i]) != 0) {
            m->n_tool_calls = i;
            for (size_t k = 0; k < i; k++) {
                free((void *)m->tool_calls[k].id);
                free((void *)m->tool_calls[k].name);
                free((void *)m->tool_calls[k].arguments);
            }
            free(m->tool_calls);
            m->tool_calls = NULL;
            m->n_tool_calls = 0;
            return -1;
        }
    }
    m->n_tool_calls = n;
    return 0;
}

/* ── multi-turn tool loop ───────────────────────────────────────────────── */

/* S11 transcript hook: fire the callback for a message just appended to the
 * list (NULL cb = no-op, preserving agent_loop_run behavior). */
static void loop_notify(agent_loop_msg_cb cb, void *user, const LlmMsg *m) {
    if (cb) cb(m, user);
}

/* The real multi-turn tool loop body.  `cb`/`cb_user` is the S11 transcript
 * hook (fired per appended message); `dcb`/`dc_user` is the S12 per-delta hook
 * (fired per delta).  Either may be NULL (disabled).  `policy` is the tool
 * allowlist enforced BEFORE every mcp_tools_call dispatch (NULL -> allow-all).
 * `out_exhausted` (may be NULL) reports the loop's OWN end-state: 1 iff the
 * loop stopped because it ran out of TURNS with tool calls still pending (the
 * last allowed turn's calls are surfaced in out_final and NOT dispatched), 0
 * for every other stop (final text turn, no tool server, backend error). */
static int run_loop(const Backend *b, const char *model,
                    const McpToolServer *tool_srv, const ToolPolicy *policy,
                    const LlmMsg *msgs, size_t n_msgs, int max_turns,
                    TurnResult *out_final, agent_loop_msg_cb cb, void *cb_user,
                    agent_loop_delta_cb dcb, void *dc_user, int *out_exhausted) {
    if (!out_final) return -1;
    if (out_exhausted) *out_exhausted = 0;
    memset(out_final, 0, sizeof *out_final);
    if (!b || !b->chat_stream) return -1;
    if (max_turns <= 0) max_turns = runner_max_turns();

    MsgList ml = { NULL, 0, 0 };
    for (size_t i = 0; i < n_msgs; i++) {
        if (msglist_append_copy(&ml, &msgs[i]) != 0) { msglist_free(&ml); return -1; }
        loop_notify(cb, cb_user, &ml.msgs[ml.n - 1]);
    }

    TurnResult turn;
    memset(&turn, 0, sizeof turn);
    int rc = 0;

    for (int t = 0; t < max_turns; t++) {
        agent_loop_free_turn(&turn); /* free the previous iteration's result */
        rc = run_single_turn_delta(b, model, ml.msgs, ml.n, &turn, dcb, dc_user);
        if (rc != 0) break;

        if (turn.n_tool_calls == 0) break; /* final text turn: done */
        if (!tool_srv) break;              /* tool_calls but nothing to dispatch */
        if (t == max_turns - 1) {          /* last allowed turn: surface tool_calls
                                            * in out_final, don't dispatch (results
                                            * would be discarded) — and SAY SO: the
                                            * task did not finish. */
            if (out_exhausted) *out_exhausted = 1;
            break;
        }

        /* Append an assistant message carrying this turn's text + its tool_calls
         * (so the model sees what it called), then dispatch each tool call and
         * append a role=tool message with its result. */
        LlmMsg asst;
        memset(&asst, 0, sizeof asst);
        asst.role = "assistant";
        if (turn.text_len) {
            asst.content = dup_n(turn.text, turn.text_len);
            if (!asst.content) { rc = -1; break; }
            asst.content_len = turn.text_len;
        }
        if (msg_set_tool_calls(&asst, turn.tool_calls, turn.n_tool_calls) != 0) {
            free((void *)asst.content);
            rc = -1; break;
        }
        if (msglist_append_owned(&ml, &asst) != 0) {
            msg_free_fields(&asst);
            rc = -1; break;
        }
        loop_notify(cb, cb_user, &ml.msgs[ml.n - 1]);

        /* Parallel dispatch: one mcp_tools_call per call id, ALL awaited (and
         * appended) before the next turn.  A tool denied by the agent's tool
         * policy is NOT dispatched (security control); instead a sentinel
         * role=tool message is appended so the loop's invariant (every
         * assistant tool_call gets a matching role=tool result) holds. */
        for (size_t j = 0; j < turn.n_tool_calls; j++) {
            const LlmToolCall *tc = &turn.tool_calls[j];

            char *result = NULL;
            if (!tool_policy_allowed(policy, tc->name)) {
                /* Filtered tool: do NOT dispatch.  Mirror the "(tool call
                 * failed)" path so the model sees the call was not executed
                 * and the call-id pairing stays intact. */
                result = dup_n("(tool disabled)", strlen("(tool disabled)"));
                if (!result) { rc = -1; break; }
            } else if (mcp_tools_call(tool_srv, tc->name,
                                      tc->arguments ? tc->arguments : "{}",
                                      &result) != 0) {
                /* Record the failure as an opaque tool error so the model can
                 * react, then continue the loop. */
                result = dup_n("(tool call failed)", strlen("(tool call failed)"));
                if (!result) { rc = -1; break; }
            }

            LlmMsg toolmsg;
            memset(&toolmsg, 0, sizeof toolmsg);
            toolmsg.role = "tool";
            toolmsg.tool_call_id = dup_n(tc->id ? tc->id : "",
                                         tc->id ? strlen(tc->id) : 0);
            if (!toolmsg.tool_call_id) { free(result); rc = -1; break; }
            toolmsg.content = result;
            toolmsg.content_len = strlen(result);
            if (msglist_append_owned(&ml, &toolmsg) != 0) {
                free((void *)toolmsg.tool_call_id);
                free((void *)toolmsg.content);
                rc = -1; break;
            }
            loop_notify(cb, cb_user, &ml.msgs[ml.n - 1]);
        }
        if (rc != 0) break;
    }

    if (rc == 0) {
        /* out_final = the last turn's result.  Transfer ownership so we don't
         * double-free. */
        *out_final = turn;
        memset(&turn, 0, sizeof turn);
    }
    msglist_free(&ml);
    agent_loop_free_turn(&turn);
    return rc;
}

int agent_loop_run_ex(const Backend *b, const char *model,
                      const McpToolServer *tool_srv, const ToolPolicy *policy,
                      const LlmMsg *msgs, size_t n_msgs, int max_turns,
                      TurnResult *out_final, agent_loop_msg_cb cb, void *cb_user) {
    /* Thin wrapper: multi-turn loop with no delta hook. */
    return run_loop(b, model, tool_srv, policy, msgs, n_msgs, max_turns, out_final,
                    cb, cb_user, NULL, NULL, NULL);
}

int agent_loop_run_delta_ex(const Backend *b, const char *model,
                            const McpToolServer *tool_srv, const ToolPolicy *policy,
                            const LlmMsg *msgs, size_t n_msgs, int max_turns,
                            TurnResult *out_final, agent_loop_msg_cb cb, void *cb_user,
                            agent_loop_delta_cb dcb, void *dc_user,
                            int *out_exhausted) {
    /* The full loop, plus the end-state the caller needs to tell "the task
     * finished" from "the TURN LIMIT stopped it" (see agent_loop.h). */
    return run_loop(b, model, tool_srv, policy, msgs, n_msgs, max_turns, out_final,
                    cb, cb_user, dcb, dc_user, out_exhausted);
}

int agent_loop_run_delta(const Backend *b, const char *model,
                         const McpToolServer *tool_srv, const ToolPolicy *policy,
                         const LlmMsg *msgs, size_t n_msgs, int max_turns,
                         TurnResult *out_final, agent_loop_msg_cb cb, void *cb_user,
                         agent_loop_delta_cb dcb, void *dc_user) {
    /* Multi-turn loop with BOTH the transcript hook and the live per-delta hook. */
    return agent_loop_run_delta_ex(b, model, tool_srv, policy, msgs, n_msgs, max_turns,
                                   out_final, cb, cb_user, dcb, dc_user, NULL);
}

int agent_loop_run(const Backend *b, const char *model,
                   const McpToolServer *tool_srv,
                   const LlmMsg *msgs, size_t n_msgs, int max_turns,
                   TurnResult *out_final) {
    /* Thin wrapper: agent_loop_run_ex with no transcript callback, no policy
     * (NULL -> allow-all). */
    return agent_loop_run_ex(b, model, tool_srv, NULL, msgs, n_msgs, max_turns,
                             out_final, NULL, NULL);
}
