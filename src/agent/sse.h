/* src/agent/sse.h — SSE (Server-Sent Events) streaming parser.
 *
 * A PURE byte-stream state machine over an untrusted byte stream.
 * The LLM transport pulls bytes off the chardev (fx_recv_some) and feeds them
 * here; sse.c does NOT touch the transport, HTTP or any socket.
 *
 * Design (the contract is the bullets below).  This is THE
 * memory-safety hotspot of — the parser is containment discipline:
 *   - NO strcpy/strcat/sprintf on network-origin bytes, ever.
 *   - The parser owns bounded grow buffers.  One LINE is capped at
 *     SSE_MAX_LINE_BYTES (16 KiB); the accumulated EVENT (event+data) is
 *     capped at SSE_MAX_EVENT_BYTES (1 MiB).  Exceeding either -> SSE_ERROR.
 *   - Emitted SseEvent slices (event_ptr/data_ptr + len) point INTO the
 *     parser's OWN retained buffer — never copies.  They stay valid until the
 *     next dispatch, then the buffer is reused.
 *   - Every malloc/realloc is checked; failure -> SSE_ERROR.
 *
 * Wire semantics (WHATWG SSE + OpenAI/Anthropic vocab):
 *   - Line endings may be CRLF, lone CR, or lone LF (all handled).
 *   - A line is `field: value`, or just `field` (empty value), or
 *     `:`-prefixed (a comment — ignored, never dispatched).  Leading spaces /
 *     tabs are stripped from each value.
 *   - A BLANK line dispatches the accumulated event.  The data payload is the
 *     concatenation of every `data:` line's value, joined with a single '\n'
 *     between successive `data:` lines; per spec one trailing '\n' is appended
 *     to a non-empty data payload.  The `event:` field (if any) rides along.
 *   - A data payload that equals exactly "[DONE]" -> SSE_DONE (the
 *     OpenAI/Anthropic terminator).  Its data slice is exactly the 6 bytes
 *     "[DONE]" (no trailing newline).
 *   - After dispatch the accumulator resets for the next event.
 *
 * Feeding contract (see sse_feed): pass body bytes as they arrive.  The
 * parser consumes ALL bytes in the buffer; if any event completed it returns
 * SSE_EVENT (or SSE_DONE if a "[DONE]" terminator was seen) and sse_event()
 * exposes the MOST RECENT completed event.  To observe every event, feed in
 * small increments (e.g. one byte per call) — the normal streaming pattern.
 */
#ifndef SSE_H
#define SSE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Caps (bounds, never exceeded). */
#define SSE_MAX_LINE_BYTES  (16 * 1024)       /* one line: name + ':' + value */
#define SSE_MAX_EVENT_BYTES (1024 * 1024)     /* one accumulated event payload */

/* sse_feed return codes. */
#define SSE_OK    0   /* consumed all bytes, no complete event yet — keep feeding */
#define SSE_EVENT 1   /* at least one complete event dispatched; read via sse_event */
#define SSE_DONE  2   /* dispatched an event whose data payload is exactly "[DONE]" */
#define SSE_ERROR -1  /* oversized line/event or OOM */

/* A dispatched event: slices into the parser's retained buffer, valid until
 * the next dispatch.  `event`/`data` may be NULL when *_len == 0. */
typedef struct SseEvent {
    const char *event; size_t event_len;  /* the `event:` field, if any */
    const char *data;  size_t data_len;   /* the joined `data:` payload */
} SseEvent;

/* Opaque-by-convention parser state.  Declared fully so callers can
 * stack-allocate (SseParser p; sse_init(&p);) — the fields below are PRIVATE,
 * owned by sse.c, and must NOT be touched by callers. */
typedef struct SseParser {
    /* most recently dispatched event (valid until next dispatch). */
    SseEvent out;

    /* current line accumulation (name ':' value), capped at SSE_MAX_LINE_BYTES. */
    char  *line; size_t line_len; size_t line_cap;

    /* accumulated event payload buffers (retained, reused across events),
     * each capped at SSE_MAX_EVENT_BYTES. */
    char  *data;  size_t data_len;  size_t data_cap;
    char  *event; size_t event_len; size_t event_cap;

    int state;             /* internal line/field state machine (see sse.c) */
    int colon_index;       /* index of ':' in the current line, or -1 */
    int line_is_comment;   /* current line started with ':' -> ignore */
} SseParser;

/* Initialize a parser (zeroed).  Always succeeds -> returns 0. */
int sse_init(SseParser *p);
/* Release all owned buffers.  NULL safe. */
void sse_free(SseParser *p);

/* Feed `len` body bytes from `buf`.  Consumes ALL bytes in the buffer.
 * Returns SSE_OK / SSE_EVENT / SSE_DONE / SSE_ERROR (see above).  After an
 * SSE_EVENT/SSE_DONE the event is available via sse_event() and the parser is
 * ready for the next event's bytes.  On SSE_ERROR the parser state is
 * indeterminate; the caller should stop and abort the stream. */
int sse_feed(SseParser *p, const unsigned char *buf, size_t len);

/* The most recently dispatched event (slices into the retained buffer, valid
 * until the next dispatch).  Returns NULL if `p` is NULL. */
const SseEvent *sse_event(SseParser *p);

#ifdef __cplusplus
}
#endif

#endif /* SSE_H */
