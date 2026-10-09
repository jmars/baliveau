/* src/llm2/openai_responses.c — LAYER-2 OpenAI RESPONSES backend (Slice S3).
 *
 * fx-harness: THE ONLY BACKEND.  Upstream shipped four (openai_responses,
 * generic, mistral, anthropic); the other three are deleted with the rest of
 * the multi-provider machinery (see fx_backend.c).  Maps the OpenAI Responses
 * SSE vocabulary onto the chardev transport (fx_transport.h) + sse (S2
 * parser), through the llm_backend.h interface.  There is no HTTP layer and
 * no TLS: the host proxy owns the endpoint, the headers and the API key.
 *
 * Vocabulary mapped (verified from live captures; see handoff-c-runtime-l2-s3):
 *   response.output_text.delta            -> DELTA_TEXT (delta fragment)
 *   response.reasoning_text.delta         -> DELTA_REASONING (delta fragment)
 *   response.output_item.added            -> start a tool-call accumulator when
 *                                            item.type == function_call
 *   response.function_call_arguments.delta-> append fragment to current args
 *   response.function_call_arguments.done -> fallback final args (if none yet)
 *   response.output_item.done             -> emit DELTA_TOOL_CALL when
 *                                            item.type == function_call
 *   response.completed                    -> DELTA_FINISH (end of stream)
 *   everything else (created / in_progress / *_done / content_part.*) -> DELTA_NONE
 *
 * There is NO "[DONE]" terminator in the Responses vocabulary — the stream ends
 * at response.completed (or at read-to-EOF).  S2's SSE_DONE is not relied on.
 *
 * Memory-safety (L2 rules): Delta slices point into the stream context's
 * bounded buffers (valid until the next parse_event / synchronous sink);
 * tool-call args accumulate in a grow buffer capped at OPENAI_ARGS_CAP (64 KiB);
 * NO strcpy/strcat/sprintf on network bytes; every malloc checked; JSON always
 * parsed with yyjson.
 */
#include "llm_backend.h"

#include "sse.h"
#include "fx_transport.h" /* fx-harness: the model transport (chardev, raw SSE) */
#include "yyjson.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Hard cap on a tool-call's accumulated arguments (attacker-shaped —
 * prompt-injection surface).  Also bounds each delta-text scratch buffer. */
#define OPENAI_ARGS_CAP (64 * 1024)

/* ── per-stream accumulator ─────────────────────────────────────────────── */

typedef struct OpenaiStream {
    /* current tool-call accumulator (valid while tool_active). */
    char *name;     size_t name_len;     size_t name_cap;
    char *call_id;  size_t call_id_len;  size_t call_id_cap;
    char *args;     size_t args_len;     size_t args_cap;
    int tool_active;

    /* scratch buffer for per-event delta slices (text / finish_reason).  Reset
     * each event; the Delta slices point here, valid until the next event. */
    char *scratch;  size_t scratch_len;  size_t scratch_cap;
} OpenaiStream;

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

/* Reset then copy `n` bytes of `s` into the buffer. */
static int set_str(char **buf, size_t *len, size_t *cap,
                   const char *s, size_t n, size_t maxcap) {
    *len = 0;
    return grow_append(buf, len, cap, s, n, maxcap);
}

void *openai_responses_create_stream(void) {
    OpenaiStream *s = (OpenaiStream *)calloc(1, sizeof *s);
    return s;
}

void openai_responses_free_stream(void *ctx) {
    if (!ctx) return;
    OpenaiStream *s = (OpenaiStream *)ctx;
    free(s->name); free(s->call_id); free(s->args); free(s->scratch);
    free(s);
}

/* ── parse_event ────────────────────────────────────────────────────────── */

int openai_responses_parse_event(void *ctx, const char *event_name,
                                 const char *data, size_t data_len,
                                 Delta *out) {
    if (!ctx || !out) return -1;
    OpenaiStream *s = (OpenaiStream *)ctx;
    memset(out, 0, sizeof *out);
    out->type = DELTA_NONE;

    if (!event_name || !data || data_len == 0) return 0;

    /* Every event payload is a JSON object.  Always yyjson, never hand-parse. */
    yyjson_doc *doc = yyjson_read(data, data_len, 0);
    if (!doc) return -1;
    yyjson_val *root = yyjson_doc_get_root(doc);
    if (!root || !yyjson_is_obj(root)) { yyjson_doc_free(doc); return -1; }

    int rc = 0;

    if (strcmp(event_name, "response.output_text.delta") == 0) {
        yyjson_val *delta = yyjson_obj_get(root, "delta");
        const char *txt = delta ? yyjson_get_str(delta) : NULL;
        if (txt) {
            size_t tl = yyjson_get_len(delta);
            s->scratch_len = 0;
            if (set_str(&s->scratch, &s->scratch_len, &s->scratch_cap,
                        txt, tl, OPENAI_ARGS_CAP) == 0) {
                out->type = DELTA_TEXT;
                out->text = s->scratch;
                out->text_len = s->scratch_len;
            } else rc = -1;
        }
    } else if (strcmp(event_name, "response.reasoning_text.delta") == 0) {
        yyjson_val *delta = yyjson_obj_get(root, "delta");
        const char *txt = delta ? yyjson_get_str(delta) : NULL;
        if (txt) {
            size_t tl = yyjson_get_len(delta);
            s->scratch_len = 0;
            if (set_str(&s->scratch, &s->scratch_len, &s->scratch_cap,
                        txt, tl, OPENAI_ARGS_CAP) == 0) {
                out->type = DELTA_REASONING;
                out->text = s->scratch;
                out->text_len = s->scratch_len;
            } else rc = -1;
        }
    } else if (strcmp(event_name, "response.output_item.added") == 0) {
        yyjson_val *item = yyjson_obj_get(root, "item");
        const char *itype = item ? yyjson_get_str(yyjson_obj_get(item, "type")) : NULL;
        if (itype && strcmp(itype, "function_call") == 0) {
            /* Begin a new tool-call accumulator. */
            s->tool_active = 1;
            s->name_len = s->call_id_len = s->args_len = 0;
            const char *nm = item ? yyjson_get_str(yyjson_obj_get(item, "name")) : NULL;
            const char *cid = item ? yyjson_get_str(yyjson_obj_get(item, "call_id")) : NULL;
            if (nm && set_str(&s->name, &s->name_len, &s->name_cap,
                              nm, yyjson_get_len(yyjson_obj_get(item, "name")),
                              OPENAI_ARGS_CAP) != 0) rc = -1;
            if (cid && set_str(&s->call_id, &s->call_id_len, &s->call_id_cap,
                               cid, yyjson_get_len(yyjson_obj_get(item, "call_id")),
                               OPENAI_ARGS_CAP) != 0) rc = -1;
        }
    } else if (strcmp(event_name, "response.function_call_arguments.delta") == 0) {
        if (s->tool_active) {
            yyjson_val *delta = yyjson_obj_get(root, "delta");
            const char *txt = delta ? yyjson_get_str(delta) : NULL;
            if (txt && grow_append(&s->args, &s->args_len, &s->args_cap,
                                   txt, yyjson_get_len(delta),
                                   OPENAI_ARGS_CAP) != 0) rc = -1;
        }
    } else if (strcmp(event_name, "response.function_call_arguments.done") == 0) {
        /* The `arguments` field carries the full final JSON.  Prefer the
         * accumulated delta fragments (authoritative), but if we somehow saw
         * the done event before any deltas, use its value. */
        if (s->tool_active && s->args_len == 0) {
            yyjson_val *args = yyjson_obj_get(root, "arguments");
            const char *txt = args ? yyjson_get_str(args) : NULL;
            if (txt && set_str(&s->args, &s->args_len, &s->args_cap,
                               txt, yyjson_get_len(args),
                               OPENAI_ARGS_CAP) != 0) rc = -1;
        }
    } else if (strcmp(event_name, "response.output_item.done") == 0) {
        yyjson_val *item = yyjson_obj_get(root, "item");
        const char *itype = item ? yyjson_get_str(yyjson_obj_get(item, "type")) : NULL;
        if (itype && strcmp(itype, "function_call") == 0 && s->tool_active) {
            /* The FINAL tool call: emit the completed accumulator. */
            out->type = DELTA_TOOL_CALL;
            out->tool_name = s->name;
            out->tool_name_len = s->name_len;
            out->tool_call_id = s->call_id;
            out->tool_call_id_len = s->call_id_len;
            out->tool_args = s->args;
            out->tool_args_len = s->args_len;
            s->tool_active = 0;
        }
    } else if (strcmp(event_name, "response.completed") == 0) {
        out->type = DELTA_FINISH;
        yyjson_val *resp = yyjson_obj_get(root, "response");
        yyjson_val *status = resp ? yyjson_obj_get(resp, "status") : NULL;
        const char *fs = status ? yyjson_get_str(status) : NULL;
        if (fs) {
            size_t fl = yyjson_get_len(status);
            s->scratch_len = 0;
            if (set_str(&s->scratch, &s->scratch_len, &s->scratch_cap,
                        fs, fl, OPENAI_ARGS_CAP) == 0) {
                out->finish_reason = s->scratch;
                out->finish_reason_len = s->scratch_len;
            }
        }
    }
    /* all other event types -> DELTA_NONE (no forwarding) */

    yyjson_doc_free(doc);
    return rc;
}

/* ── chat_stream ────────────────────────────────────────────────────────── */

int openai_responses_chat_stream(const Backend *b, const char *req_json,
                                 size_t req_len, sse_sink_cb sink, void *user) {
    if (!b || !b->base_url) return -1;

    void *ctx = openai_responses_create_stream();
    if (!ctx) return -1;

    int rc = -1;
    int fd = fx_transport_open(NULL, 0);
    if (fd < 0) goto out;

    /* fx-harness: NO HTTP ENVELOPE.  One framed request goes out; the
     * provider's raw SSE body comes back.  The endpoint, the headers and the
     * API KEY all belong to the host proxy — nothing here knows the base_url
     * and `b->api_key` is deliberately unused, so no credential crosses the
     * channel. */
    if (fx_send_request(fd, req_json, req_len) != 0) {
        close(fd);
        goto out;
    }

    SseParser sse; sse_init(&sse);
    int finished = 0;
    int err = 0;
    /* fx-harness: buffered read, BYTE-AT-A-TIME feed.  sse_feed dispatches per
     * event, so feeding a whole chunk would leave later events in the chunk
     * un-dispatched or mis-ordered. */
    unsigned char rbuf[4096];
    int nread = 0, rpos = 0;
    for (;;) {
        if (rpos >= nread) {
            nread = fx_recv_some(fd, rbuf, sizeof rbuf);
            rpos = 0;
            if (nread < 0) { err = 1; break; }
            if (nread == 0) break; /* EOF: the proxy closed the stream */
        }

        unsigned char byte = rbuf[rpos++];
        int sr = sse_feed(&sse, &byte, 1);
        if (sr == SSE_ERROR) { err = 1; break; }
        if (sr == SSE_DONE) {
            /* Bare "[DONE]" terminator (chat-completions-style backends); the
             * Responses vocabulary uses response.completed instead.  Treat it
             * as a clean finish — never as JSON to parse. */
            Delta d; memset(&d, 0, sizeof d); d.type = DELTA_FINISH;
            if (sink) sink(&d, user);
            finished = 1;
            break;
        }
        if (sr == SSE_EVENT) {
            const SseEvent *ev = sse_event(&sse);
            Delta d;
            if (b->parse_event(ctx, ev->event, ev->data, ev->data_len, &d) != 0) {
                err = 1; break;
            }
            if (d.type == DELTA_FINISH) {
                if (sink) sink(&d, user);
                finished = 1;
                break;
            }
            if (d.type != DELTA_NONE && sink) sink(&d, user);
        }
    }
    sse_free(&sse);

    if (!finished && !err) {
        /* Clean EOF without an explicit response.completed: the Responses
         * stream has no [DONE]; end the stream with DELTA_FINISH. */
        Delta d; memset(&d, 0, sizeof d); d.type = DELTA_FINISH;
        if (sink) sink(&d, user);
        finished = 1;
    }
    rc = err ? -1 : 0;

    close(fd);

out:
    openai_responses_free_stream(ctx);
    return rc;
}

/* ── backend accessor ───────────────────────────────────────────────────── */

const Backend *openai_responses_backend(void) {
    static const Backend b = {
        .base_url     = "http://127.0.0.1:8321",
        .chat_stream  = openai_responses_chat_stream,
        .parse_event  = openai_responses_parse_event,
        .impl         = NULL,
        .format       = RESPONSES,
        .api_key      = NULL,
    };
    return &b;
}
