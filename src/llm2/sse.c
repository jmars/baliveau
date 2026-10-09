/* src/llm2/sse.c — LAYER-2 SSE (Server-Sent Events) streaming parser (Slice S2).
 *
 * Pure byte-stream state machine.  See sse.h for the design + wire semantics.
 *
 * State machine (per plan): LINE_START -> FIELD_NAME -> FIELD_VALUE, with a
 * transient CR state to absorb CRLF (and a blank line triggering dispatch).
 *   SSE_STATE_START  : beginning of a line, no bytes yet.
 *   SSE_STATE_NAME   : accumulating a field name (before any ':').
 *   SSE_STATE_VALUE  : accumulating a field value (after the ':'), or a
 *                      comment line (':' first char).
 *   SSE_STATE_CR     : just ended a line with '\r'; absorb an optional
 *                      following '\n' (CRLF), else the byte starts a new line.
 *
 * Memory-safety: every byte accumulates into a bounded grow buffer via
 * grow_append_cap() (malloc/realloc always checked, never writes past cap).
 * Lines are capped at SSE_MAX_LINE_BYTES; the accumulated event payloads at
 * SSE_MAX_EVENT_BYTES.  NO strcpy/strcat/sprintf anywhere.
 */
#include "sse.h"

#include <stdlib.h>
#include <string.h>

/* internal line/field states */
enum {
    SSE_STATE_START = 0,
    SSE_STATE_NAME,
    SSE_STATE_VALUE,
    SSE_STATE_CR
};

/* Append `n` bytes of `src` to the grow buffer (*buf,*len,*cap), never letting
 * *len exceed `maxcap` (the caller's hard cap).  Always keeps a NUL at [*len]
 * (not part of the logical payload) for convenience.  Returns 0 on success,
 * -1 on oversize (would exceed maxcap) or OOM. */
static int grow_append_cap(char **buf, size_t *len, size_t *cap,
                           const char *src, size_t n, size_t maxcap) {
    if (*len > maxcap || n > maxcap - *len) return -1; /* oversize: DoS guard */
    if (*len + n + 1 > *cap) { /* need one extra for the NUL */
        size_t nc = *cap ? *cap * 2 : 256;
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

/* Reset the current-line accumulation for the next line. */
static void line_reset(SseParser *p) {
    p->line_len = 0;
    p->colon_index = -1;
    p->line_is_comment = 0;
}

/* Reset the accumulated event payloads (buffers are retained and reused, so
 * previously emitted SseEvent slices become invalid — the caller must consume
 * them before the next dispatch). */
static void event_reset(SseParser *p) {
    p->data_len = 0;
    p->event_len = 0;
}

int sse_init(SseParser *p) {
    if (!p) return -1;
    memset(p, 0, sizeof *p);
    p->state = SSE_STATE_START;
    p->colon_index = -1;
    return 0;
}

void sse_free(SseParser *p) {
    if (!p) return;
    free(p->line); p->line = NULL;
    free(p->data); p->data = NULL;
    free(p->event); p->event = NULL;
    p->line_cap = p->data_cap = p->event_cap = 0;
}

const SseEvent *sse_event(SseParser *p) {
    return p ? &p->out : NULL;
}

/* Process one complete (non-blank) line: extract the field name + value and
 * fold it into the accumulated event.  Returns SSE_ERROR on oversize/OOM, else
 * SSE_OK. */
static int process_line(SseParser *p) {
    if (p->line_len > 0 && !p->line_is_comment) {
        const char *name = p->line;
        size_t name_len;
        const char *val;
        size_t val_len;
        if (p->colon_index >= 0 && p->colon_index < (int)p->line_len) {
            name_len = (size_t)p->colon_index;
            /* The ':' is NOT stored in p->line: sse_byte() sets colon_index and
             * switches to VALUE without appending the ':' byte, so the value
             * starts at p->line[name_len] (not name_len+1).  The previous
             * +1/-1 skipped line[name_len], silently dropping the first value
             * byte for `field:value` lines with no space after the colon
             * (e.g. `data:[DONE]` -> `DONE]`, so the terminator was missed). */
            val = p->line + name_len;
            val_len = p->line_len - name_len;
            /* strip leading whitespace from the value (SSE "data: value"
             * streams routinely pad with extra spaces/tabs; the LLM transport
             * only carries JSON or "[DONE]", neither of which is sensitive to
             * leading whitespace). */
            while (val_len > 0 && (val[0] == ' ' || val[0] == '\t')) {
                val++;
                val_len--;
            }
        } else {
            name_len = p->line_len; /* bare field: empty value */
            val = p->line + p->line_len;
            val_len = 0;
        }

        if (name_len == 4 && memcmp(name, "data", 4) == 0) {
            /* join successive data values with a single '\n' separator; the
             * trailing '\n' is appended at dispatch time. */
            if (p->data_len > 0 &&
                grow_append_cap(&p->data, &p->data_len, &p->data_cap,
                                "\n", 1, SSE_MAX_EVENT_BYTES) != 0)
                return SSE_ERROR;
            if (grow_append_cap(&p->data, &p->data_len, &p->data_cap,
                                val, val_len, SSE_MAX_EVENT_BYTES) != 0)
                return SSE_ERROR;
        } else if (name_len == 5 && memcmp(name, "event", 5) == 0) {
            p->event_len = 0; /* last event: field wins (SSE spec) */
            if (grow_append_cap(&p->event, &p->event_len, &p->event_cap,
                                val, val_len, SSE_MAX_EVENT_BYTES) != 0)
                return SSE_ERROR;
        }
        /* all other fields (id, retry, ...) are ignored by this consumer */
    }
    line_reset(p);
    return SSE_OK;
}

/* Dispatch the accumulated event on a blank line.  If the joined data payload
 * equals exactly "[DONE]" (6 bytes) the event is dispatched with data =
 * precisely "[DONE]" and SSE_DONE is returned; otherwise a trailing '\n' is
 * appended to a non-empty payload and SSE_EVENT is returned. */
static int dispatch(SseParser *p) {
    if (p->data_len == 6 && memcmp(p->data, "[DONE]", 6) == 0) {
        p->out.event = p->event;
        p->out.event_len = p->event_len;
        p->out.data = p->data;
        p->out.data_len = 6; /* exactly "[DONE]", no trailing newline */
        event_reset(p);
        return SSE_DONE;
    }
    if (p->data_len > 0 &&
        grow_append_cap(&p->data, &p->data_len, &p->data_cap,
                        "\n", 1, SSE_MAX_EVENT_BYTES) != 0)
        return SSE_ERROR;
    p->out.event = p->event;
    p->out.event_len = p->event_len;
    p->out.data = p->data;
    p->out.data_len = p->data_len;
    event_reset(p);
    return SSE_EVENT;
}

/* Process a single byte.  Returns SSE_OK / SSE_EVENT / SSE_DONE / SSE_ERROR. */
static int sse_byte(SseParser *p, unsigned char b) {
    switch (p->state) {
    case SSE_STATE_START:
        if (b == '\r') { p->state = SSE_STATE_CR; return dispatch(p); } /* blank line */
        if (b == '\n') { return dispatch(p); }                            /* blank line */
        if (b == ':') { p->line_is_comment = 1; p->state = SSE_STATE_VALUE; return SSE_OK; }
        p->colon_index = -1;
        if (grow_append_cap(&p->line, &p->line_len, &p->line_cap,
                            (const char *)&b, 1, SSE_MAX_LINE_BYTES) != 0)
            return SSE_ERROR;
        p->state = SSE_STATE_NAME;
        return SSE_OK;

    case SSE_STATE_NAME:
        if (b == '\r') { p->state = SSE_STATE_CR; return process_line(p); }
        if (b == '\n') { p->state = SSE_STATE_START; return process_line(p); }
        if (b == ':') { p->colon_index = (int)p->line_len; p->state = SSE_STATE_VALUE; return SSE_OK; }
        if (grow_append_cap(&p->line, &p->line_len, &p->line_cap,
                            (const char *)&b, 1, SSE_MAX_LINE_BYTES) != 0)
            return SSE_ERROR;
        return SSE_OK;

    case SSE_STATE_VALUE:
        if (b == '\r') { p->state = SSE_STATE_CR; return process_line(p); }
        if (b == '\n') { p->state = SSE_STATE_START; return process_line(p); }
        if (grow_append_cap(&p->line, &p->line_len, &p->line_cap,
                            (const char *)&b, 1, SSE_MAX_LINE_BYTES) != 0)
            return SSE_ERROR;
        return SSE_OK;

    case SSE_STATE_CR:
        if (b == '\n') { p->state = SSE_STATE_START; return SSE_OK; } /* CRLF */
        p->state = SSE_STATE_START; /* lone CR: b starts a new line */
        return sse_byte(p, b);

    default:
        return SSE_ERROR;
    }
}

int sse_feed(SseParser *p, const unsigned char *buf, size_t len) {
    if (!p || (len && !buf)) return SSE_ERROR;
    int result = SSE_OK;
    for (size_t i = 0; i < len; i++) {
        int r = sse_byte(p, buf[i]);
        if (r == SSE_DONE) return SSE_DONE; /* terminator: stop immediately */
        if (r == SSE_EVENT) { result = SSE_EVENT; continue; } /* keep consuming */
        if (r < 0) return SSE_ERROR;
    }
    return result;
}
