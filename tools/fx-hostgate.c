/* tools/fx-hostgate.c — THE HOST PROXY (design record §7.6; plan
 * handoff-hostgate-plan2), slice P1: the stream-transparent skeleton;
 * slice P2: THE ONE LOG and the request <-> response <-> next-request join.
 *
 * A sibling of the host seats (fx-audit / fx-report / fx-select / fx-claim):
 * HOST-SIDE, AGENT-UNWRITABLE, a function of observable state — here, the
 * state is the WIRE.  The guest harness has no socket layer (Makefile header;
 * src/agent/fx_transport.c): the model transport is a character device, and
 * whoever holds its other end holds the endpoint, the TLS and the API key.
 * This program is that other end.
 *
 * P1 SCOPE — TRANSPARENCY ONLY, NO POLICY.  The proxy reads the guest's
 * framed request and streams the upstream bytes back VERBATIM as raw SSE:
 * no HTTP envelope, no chunking, no judgement, no rewriting.  The decode
 * side is isolated in read_frame() and the response side in the single
 * write_all() of the upstream buffer; the P3 rewriter lands behind exactly
 * those two seams.  P1's deliverable is the gate that proves the
 * transparency (tests/test_hostgate.sh, `make test-hostgate`): a host-built
 * guest harness running the whole loop THROUGH this proxy must print the
 * same marker as running it off the canned file directly, and a mangling
 * proxy must FAIL that gate — the failure direction of a transparency
 * mistake is LOUD (marker mismatch), never silent.
 *
 * P2 SCOPE — THE ONE LOG, AND THE JOIN.  STILL NO POLICY: a call is neither
 * accepted nor denied by judgement here, only RECORDED and JOINED.
 *
 *   THE LOG (--log PATH, required): append-only JSONL, ONE ROW PER CALL, the
 *   single writer is this proxy, and the file is a NEW host-side file — never
 *   inside the store, never shared with the guest's transcript/runstore.  A
 *   call row is written when the call is observed in the decode
 *   (response.output_item.done, item.type=="function_call" — the event whose
 *   arrival makes the guest emit the call, openai_responses.c:184-194), with
 *   pending:true; when a LATER request frame carries a function_call_output
 *   whose call_id matches, the SAME row is resolved (pending:false, outcome
 *   attached).  In-place resolution is why the file is rewritten atomically
 *   (temp + fsync + rename) on each mutation by its single writer, rather
 *   than byte-appended: rows are only ever ADDED, and the only change to an
 *   existing row is its outcome half arriving.
 *
 *   THE JOIN NEEDS NO NEW CHANNEL (measured): the guest replays every tool
 *   result as a function_call_output item in its NEXT request
 *   (agent_loop.c:91-104) and sends that request down the SAME chardev it
 *   reads the decode from (fx_transport.c:57-85).  The proxy sees all three
 *   legs; the join key is call_id — never the tool name, never the position.
 *
 *   NO VERDICT FIELD.  No policy has run in this slice, so no row says
 *   `allowed` or carries `verdict`/`author`/`refusal_name`/`reason`/
 *   `denial_text` — those are RESERVED for P3/P5, and a row that claimed
 *   allow/deny now would be a claim wider than the evidence.  The gate
 *   asserts their absence, so P3's arrival will be visible in the record.
 *   For the same honesty: `session`/`run` are emitted as explicit nulls —
 *   the wire frame carries NO session/run identity (build_responses_request
 *   sends model/stream/input only, agent_loop.c:68-104), so null is the
 *   truest value this slice can determine.
 *
 *   BOUNDING: every free-text field (args, outcome) is length-capped with an
 *   EXPLICIT truncation marker — a silently truncated field is a lie (the
 *   S2 review found exactly that defect in fx-report).
 *
 *   A JOIN THAT CANNOT FIRE FAILS OPEN IN THE RECORD, VISIBLY: at exit every
 *   still-pending row is reported on stderr (UNRESOLVED, naming call_ids)
 *   AND a terminal `proxy-exit` summary row is appended to the log naming
 *   them.  Silence is the failure mode: a log merely missing its outcome
 *   half must never look like a log where nothing needed joining.  A missed
 *   join is a SILENT DEGRADATION (the record looks complete but is not) —
 *   the gate catches it by CONTENT, not by exit status (the P2 mutant, a
 *   join pass compiled out, still exits 0 with a wrong record).
 *
 * THE CONTRACT SPOKEN (MEASURED, src/agent/fx_transport.c:57-85):
 *   guest -> host   "<len>\n<json>" — a DECIMAL BYTE COUNT, a newline, then
 *                   the body; the count is authoritative (JSON is not
 *                   newline-safe to delimit) and the frame may arrive across
 *                   SEVERAL reads, so completeness is framed on the count,
 *                   never on one-read-is-one-frame.
 *   host -> guest   raw SSE.  response.completed must be the LAST event
 *                   (the guest breaks its read loop on it,
 *                   openai_responses.c:273-278); the proxy simply streams
 *                   the canned stream whole and writes nothing of its own.
 *
 * TRANSPORT — A PTY PAIR, NOT A FIFO (MEASURED; do not regress):
 *   the guest opens FX_CHARDEV O_RDWR|O_APPEND per turn
 *   (fx_transport.c:41-54).  A FIFO opened O_RDWR SELF-READS: the guest
 *   becomes a reader on its own request frame, consumes it, parses it as SSE
 *   with no recognised events, synthesizes FINISH at EOF
 *   (openai_responses.c:283-288) and returns an empty result — LOUD but
 *   FLAKY, so no transparency proof.  A PTY pair has no self-read: the
 *   guest opens the SLAVE by path (MEASURED: open(ttyname, O_RDWR|O_APPEND)
 *   works, slave writes arrive on the master and vice versa, and lseek gives
 *   ESPIPE — which fx_send_request already expects and ignores), the proxy
 *   holds the MASTER.  The line discipline is set RAW through the master
 *   (cfmakeraw): canonical mode would echo the guest's request back into its
 *   own read stream, and ONLCR would rewrite the SSE's \n to \r\n.
 *
 * P3 SCOPE — THE DECODE GATE (H2) + THE OUTBOUND SUBSTITUTION.  THE
 * SOUNDNESS-CRITICAL SLICE.
 *
 *   THE GATE'S INVARIANT, STATED SO THE GATE CAN ASSERT IT: for a DENIED
 *   call, the true verb name NEVER crosses the chardev into the guest AS A
 *   CALL NAME — the name field of every function_call item the proxy
 *   forwards (response.output_item.added, response.output_item.done, and
 *   the output array inside response.completed) carries the reserved name
 *   `fx_host_denied` instead.  (MEASURED WIRE RESIDUALS, named not hidden:
 *   model PROSE that merely mentions the verb — the reasoning deltas, the
 *   reasoning items in output_item.done and completed's output array — is
 *   not a call name and crosses; it can dispatch nothing.  The envelope's
 *   ECHOED TOOLS CATALOG (response.tools[].name inside response.created /
 *   response.in_progress, an artifact of the canned recording) also carries
 *   the recorded request's tool name — the guest's parser never reads
 *   .response.tools (those events are DELTA_NONE, and the accumulator is
 *   the only dispatch feed), and once P5 has the host INJECT the tools
 *   array the echo on a live lane reflects the host's own catalog.  Both
 *   residuals are byte-level leaks of the WORD, never of a dispatchable
 *   call item.)  The ARGS cross DELIBERATELY: they are inert without a
 *   dispatcher and they are the intent record §1b wants.  The call_id
 *   crosses UNTOUCHED: it is the join key for BOTH legs.
 *
 *   THE MECHANISM (decided by measurement in plan obs 1/2; do not
 *   re-litigate): the proxy BUFFERS each function_call output-item WHOLE —
 *   added -> arguments.delta* -> done — and judges at ITEM COMPLETION, with
 *   the name and the full arguments in hand and NOTHING executed (this is
 *   what makes BEFORE structural).  Accepted items are forwarded with their
 *   buffered bytes VERBATIM (the P1 transparency property); denied items
 *   are re-serialized with item.name -> fx_host_denied in added AND done
 *   AND inside completed's output array.  WHY EVERY EVENT: MEASURED against
 *   the guest's parser — the tool accumulator is fed by EXACTLY ONE event
 *   shape, output_item.added with item.type=="function_call"
 *   (openai_responses.c:146-161), and that is where the name is taken; at
 *   output_item.done the guest emits THE ACCUMULATOR'S name
 *   (openai_responses.c:181-194), and response.completed's output array is
 *   never read for a name (:195-208 reads only status).  A rewrite that
 *   misses the ADDED event therefore lets the true name reach the
 *   accumulator and the guest dispatches it: a SILENT ALLOW — which is why
 *   the gate's completeness mutation removes ONLY the added-event rewrite.
 *   The completed array is rewritten anyway so the byte-level invariant
 *   holds against a guest that reads raw.
 *
 *   NAMED CONSEQUENCE (not hidden): buffering a tool-call item means its
 *   events are HELD until the item completes — text and reasoning deltas
 *   still stream past it, but a slow-dripping function_call adds the whole
 *   item's latency to the guest's turn.  That latency is the price of
 *   "BEFORE"; a decode-leg rewrite made after the added event crossed can
 *   never un-cross it.
 *
 *   THE RESERVED NAME fx_host_denied: passes the guest's
 *   validate_identifier charset and collides with no verb in the fx-verbs
 *   catalog, so even an allow-all lane cannot execute it
 *   (fx-verbs-server.c refuses an unknown name with -32602 ->
 *   mcp_tools_call returns -1 -> the guest records "(tool call failed)"
 *   and dispatches NOTHING).  Do not rely on the lane config; the staged
 *   config sets no tool lists at all.  (The proxy's own startup REFUSAL on a
 *   future catalog collision is P4's, now built: see the P4 SCOPE block — and
 *   that block's refusal is what keeps the claim above true as the catalog
 *   grows.)
 *
 *   THE OUTBOUND SUBSTITUTION — the denial must reach the model as the
 *   CALL'S OWN RESULT.  The guest can only synthesize a sentinel ("(tool
 *   disabled)" / "(tool call failed)") because it cannot know why; the
 *   host owns the outbound leg and substitutes the truth on the NEXT
 *   request frame: (i) a function_call item whose call_id is in the deny
 *   map gets its name RESTORED to the true name (the guest serialized the
 *   reserved name; without the restore the model would see a call it never
 *   made); (ii) a function_call_output item whose call_id is in the map
 *   gets its output REPLACED with the denial text.  KEYED ON call_id —
 *   never the name, never the position — and UNCONDITIONAL on membership
 *   (not on content match), so even a guest that writes a bogus output for
 *   a denied call_id has it overwritten: the model's context is
 *   host-authored for every denial.  In the OFFLINE arm the upstream is a
 *   canned file, so "what the host would forward" is invisible on the wire
 *   — --dump-requests PATH records the REWRITTEN model-facing frame (one
 *   compact JSON line per turn); without it the outbound half could not be
 *   gated at all.  (P10's live lane sends this same rewritten frame up the
 *   wire.)
 *
 *   UNJOINED OUTPUTS (telemetry, not a stop): a function_call_output whose
 *   call_id matches NO call the host ever decoded -> an `unjoined-output`
 *   row; an output for a DENIED call_id whose content is not one of the two
 *   known sentinels -> an `echo-anomaly` row.  The record keeps the
 *   evidence (§6b auditing); the enforcement is the name rewrite, which is
 *   structural, so these rows are instruments, not teeth.
 *
 *   THE POLICY, AND THE HONESTY RULE: P3's policy is a PLACEHOLDER to
 *   exercise the gate — a pinned host-side denylist (--deny NAME, the
 *   brief's "deny get_weather").  The real authors are P6 (operator
 *   allow/deny) and P7 (the claim judgment); they do not exist yet, and the
 *   log's `author` field names what ACTUALLY RAN (`denylist`) — never
 *   `ops`, never `claim`: a row claiming them would be a record wider than
 *   the evidence.  With NO --deny, NO policy ran and NO verdict field is
 *   emitted (the P2 shape, byte-identical — its phases must stay green).
 *   STATED RESIDUALS: §6b unchanged — a root agent in the guest can still
 *   act DIRECTLY, outside any tool call; this closes the tool-call channel
 *   only (auditing, not proofing).  The ARGS of a denied call cross into
 *   the guest (deliberately); a guest that reads them is already the §6b
 *   residual.
 *
 * P4 SCOPE — THE RESERVED-NAME CONTRACT.  P3 USES `fx_host_denied`; P4 makes
 *   its soundness a CHECKED property instead of an accident, and the check is
 *   a STARTUP REFUSAL because a startup refusal is the only place it can be
 *   LOUD:
 *   (a) the name must pass the guest's validate_identifier charset
 *       (^[A-Za-z0-9._-]+$, not starting with '-'; src/runner.c:49-70) — a
 *       future rename that produced an unparseable name is caught here rather
 *       than as a shape failure inside the guest;
 *   (b) the name must collide with NO verb of the proxy's own PINNED catalog.
 *       A collision makes the "reserved" name CALLABLE — an allow-all lane
 *       (the staged config declares no tool lists at all, so
 *       tool_policy_allowed is ALLOW-ALL, tool_policy.c:85-97) dispatches it
 *       and the verbs server answers — which is a SILENT ALLOW.  Refuse, do
 *       not warn;
 *   (c) the catalog carries a sha256 PIN verified at startup with the
 *       vendored sha256_hex (the fx-verbs PINS discipline,
 *       fx-verbs-server.c:941-990).  Editing the catalog without re-pinning is
 *       loud, because the collision check is worth exactly the bytes it
 *       checks.
 *   The catalog is a HOST-SIDE MIRROR of the closed fx-verbs vocabulary
 *   (VERBS[] in tools/fx-verbs-server.c:2321-2456, 13 verbs — read from the
 *   table, not from a plan line).  Its provenance is re-checked BY THE GATE
 *   against that table (`--print-catalog`, one name per line), so a verb
 *   added to the verbs server tomorrow surfaces as a gate failure rather than
 *   as a silent collision later.  DIRECTION: a name collision is a SILENT
 *   ALLOW, and the gate proves it by making a colliding name CALLABLE in the
 *   no-contract build.
 *
 * P5 SCOPE — THE JUSTIFICATION RIDES WITH THE CALL.  Nothing new crosses the
 *   chardev: the justification is a field OF THE CALL's arguments, in the same
 *   model turn, which is what makes BEFORE structural (nothing has executed
 *   when the host judges).  --require-justification arms three things:
 *   (1) THE HOST INJECTS THE `tools` ARRAY into the request it forwards
 *       (MEASURED: the guest sends none — "tools array omitted (S6 sends
 *       none)", agent_loop.c:68-69 — and the host owns the wire), one entry
 *       per pinned catalog verb, each `parameters` schema declaring
 *       `justification` as a REQUIRED string property, so an unjustified call
 *       is schema-invalid before any policy runs.  A `tools` member already
 *       in the frame is REPLACED by the host's catalog: the host owns it.
 *   (2) THE HOST JUDGES THE JUSTIFICATION at ITEM COMPLETION, on the
 *       arguments the GUEST will dispatch: the accumulated
 *       function_call_arguments.delta fragments, with the
 *       response.function_call_arguments.done EVENT's `arguments` used ONLY
 *       when no delta arrived — mirroring openai_responses.c:171-194 exactly.
 *       The output_item.done ITEM's own `arguments` member is NEVER a
 *       judgment source (at that event the guest emits its accumulator as-is
 *       and does not read the member — a fallback to it made the host judge a
 *       field the guest drops, reproduced by the gate's phase 37):
 *       the mirror is load-bearing, not
 *       pedantry: a real provider sends arguments:"" in added and every byte
 *       in the deltas, so a judge reading the item's own field would deny
 *       EVERY honest call while looking protective.  ABSENT (`justification`
 *       not present, or no arguments at all) -> denied by name
 *       `absent-justification`; MALFORMED (not a string, or blank) ->
 *       `malformed-justification`.  Both are HOST refusals, so they take the
 *       SAME path as a policy denial: the true name never crosses, and the
 *       denial reaches the model through the EXISTING P3 outbound
 *       substitution, with author:"justification".  A call WITH a valid
 *       justification is judged by the policy normally.
 *   (3) THE DENIAL-RATE INSTRUMENT, because the failure this slice can
 *       introduce is invisible by construction: a required-justification
 *       schema the model cannot satisfy DEGRADES TO AN EFFECTIVELY DEAD AGENT
 *       while every log line looks protective (calls denied, nothing
 *       executing, "working").  So every armed turn emits a `turn-stats` row
 *       (calls / denied / allowed / denial-reason breakdown) AND a stderr
 *       line, the proxy-exit row carries the run aggregate, and a turn whose
 *       calls were ALL denied prints a loud 100%-denied line naming the
 *       dead-agent shape.  A gate that only checked "denials happen" cannot
 *       see this, which is why the instrument has its own mutation blind
 *       (FH_MUTANT_NO_DENIAL_RATE).
 *   ZERO GUEST CHANGE, and the reason it holds: every verb extracts its
 *   arguments BY KEY and ignores unknown keys (fx-verbs-server.c:2548-2557),
 *   so a riding `justification` breaks no verb and nothing needs stripping —
 *   the argument bytes the model sent are the bytes the verb sees.  The gate
 *   re-verifies that PER VERB against the REAL server (a differential probe
 *   of build/fx-verbs-server with and without the riding key) instead of
 *   trusting the line above.
 *
 * TURN MECHANICS — the two things slice P1 was asked to MEASURE, not assume:
 *   (a) the guest OPENS the device per turn and CLOSES it at the turn
 *       boundary (openai_responses.c:226/:292): the slave path stays valid
 *       across turns against ONE master — the gate drives two turns through
 *       one proxy process to prove the reopen;
 *   (b) when the last slave fd closes, the master's read returns EIO.  That
 *       is a TURN BOUNDARY here, not a fatal error: the proxy reports it
 *       and waits for the next turn's frame.  MEASURED: after EIO the read
 *       keeps returning immediately until a slave reopens, so the retry
 *       backs off briefly instead of spinning.
 */
/* The pty APIs (posix_openpt/grantpt/unlockpt/ptsname) are X/Open: the
 * tree's shared CFLAGS pin only _POSIX_C_SOURCE, so this file asks for
 * XPG6 itself (the tree's no-new-dependency rule: this is libc, not a
 * dependency).  cfmakeraw stays covered by the CFLAGS' _DEFAULT_SOURCE. */
#define _XOPEN_SOURCE 600
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#include "dhall.h" /* sha256_hex — the vendored dhall-c hash, P4's catalog pin
                    * (the same helper fx-verbs-server.c:985 checks PINS with;
                    * the Makefile links src/vendor/dhall-c/sha256.c only, as
                    * it already does for fx-audit/fx-report/fx-claim) */
#include "yyjson.h"

static const char *prog = "fx-hostgate";

static void note(const char *fmt, ...) {
    va_list ap;
    fputs(prog, stderr);
    fputs(": ", stderr);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}

static void die_errno(const char *what) {
    note("FATAL: %s: errno=%d", what, errno);
    exit(1);
}

/* Exact write loop (the shape fx_send_request uses): EINTR-retried, partial
 * writes absorbed.  Returns 0, or -1 with errno set. */
static int write_all(int fd, const unsigned char *buf, size_t len) {
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(fd, buf + off, len - off);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        off += (size_t)n;
    }
    return 0;
}

static void *xmalloc(size_t n) {
    void *p = malloc(n ? n : 1);
    if (!p) die_errno("malloc");
    return p;
}

static char *xstrdup(const char *s) {
    size_t n = strlen(s);
    char *d = xmalloc(n + 1);
    memcpy(d, s, n + 1);
    return d;
}

/* ── the one log (P2) ─────────────────────────────────────────────────────── */

#define FH_BOUND 512 /* free-text cap; a cut is MARKED, never silent */
#define FH_FRAME_MAX (16u << 20) /* refuse absurd frames/fields, don't drop */

/* Forward declarations: the exit report and the P5 denial-rate instrument
 * (below, with the log) render the POLICY state ("which author ran?") and a
 * text buffer, both defined further down with their own sections — the log
 * comes first in this file because every seat below writes to it. */
struct tbuf;
static int policy_armed(void);
static void tb_put(struct tbuf *t, const char *s, size_t n);
static void tb_puts(struct tbuf *t, const char *s);
#ifndef FH_MUTANT_NO_DENIAL_RATE /* the instrument is the only caller */
static char *reasons_breakdown_json(const char *const *names,
                                    const size_t *counts, size_t n);
#endif

/* THE HONEST AUTHOR/REFUSAL NAMES (P3 + P5; see the P3/P5 header blocks).
 * P3's author is a placeholder denylist — never the P6/P7 authors; P5's is the
 * justification check, and its refusal names are salvaged from the fx-init S3b
 * list the plan names.  Every denial names its author AND its reason, and the
 * refusal is BY NAME (never a bare rejection).  Declared here because the log
 * writer below renders them. */
#define FH_AUTHOR_DENYLIST "denylist"
#define FH_REFUSAL_DENYLIST "denied-by-denylist"
#define FH_AUTHOR_JUSTIFY "justification"
#define FH_REFUSAL_ABSENT_JUSTIFY "absent-justification"
#define FH_REFUSAL_MALFORMED_JUSTIFY "malformed-justification"
/* A refusal-shaped entry that names NO refusing author: an item that never
 * completed was never JUDGED, so no policy refused it.  Used as the reason and
 * (prefixed) as the substitution text for such an item, so the record cannot
 * carry an empty denial where a real one is owed. */
#define FH_REASON_UNJUDGED_ITEM "item never completed and was not judged"

/* Bounded copy of a free-text field: capped at FH_BOUND bytes with an
 * explicit truncation marker naming the original length when cut. */
#ifdef FH_MUTANT_NO_BOUND
/* P2 FIX MUTATION BLIND (build/fx-hostgate-unbound): the bound compiled OUT
 * — every free-text field renders verbatim.  The failure is a WRONG RECORD
 * (model-controlled text entering an append-only host log uncapped, with no
 * marker), not a crash; the gate's bound phase must catch it by content on
 * exactly its own fixture. */
static char *bound_copy(const char *s) { return xstrdup(s); }
#else
static char *bound_copy(const char *s) {
    size_t n = strlen(s);
    if (n <= FH_BOUND) return xstrdup(s);
    char mark[64];
    snprintf(mark, sizeof mark, "...[TRUNCATED from %zu bytes]", n);
    size_t mark_len = strlen(mark);
    size_t keep = FH_BOUND > mark_len ? FH_BOUND - mark_len : 0;
    char *d = xmalloc(keep + mark_len + 1);
    memcpy(d, s, keep);
    memcpy(d + keep, mark, mark_len + 1);
    return d;
}
#endif /* FH_MUTANT_NO_BOUND */

/* JSON string literal with escapes (control chars, quote, backslash). */
static char *json_str(const char *s) {
    size_t n = strlen(s);
    char *out = xmalloc(6 * n + 3);
    char *w = out;
    *w++ = '"';
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        switch (c) {
        case '"': *w++ = '\\'; *w++ = '"'; break;
        case '\\': *w++ = '\\'; *w++ = '\\'; break;
        case '\b': *w++ = '\\'; *w++ = 'b'; break;
        case '\f': *w++ = '\\'; *w++ = 'f'; break;
        case '\n': *w++ = '\\'; *w++ = 'n'; break;
        case '\r': *w++ = '\\'; *w++ = 'r'; break;
        case '\t': *w++ = '\\'; *w++ = 't'; break;
        default:
            if (c < 0x20) w += sprintf(w, "\\u%04x", c);
            else *w++ = (char)c;
        }
    }
    *w++ = '"';
    *w = '\0';
    return out;
}

static void now_ts(char *buf, size_t cap) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    struct tm tm;
    gmtime_r(&ts.tv_sec, &tm);
    strftime(buf, cap, "%Y-%m-%dT%H:%M:%SZ", &tm);
}

enum {
    ROW_CALL = 0, /* one row per tool call observed in the decode */
    ROW_EXIT = 1, /* the terminal proxy-exit summary row */
    ROW_ANOM_UNJOINED = 2, /* P3 telemetry: an output whose call_id matches no decoded call */
    ROW_ANOM_ECHO = 3,     /* P3 telemetry: a denied call's output is not a known sentinel */
    ROW_ANOM_UNRESOLVED_SUBST = 4, /* P3-fix: a denied call whose outbound substitution never fired */
    ROW_TURNSTATS = 5,     /* P5: the denial-rate instrument, one row per armed turn */
};

enum {
    VERDICT_NONE = -1,   /* no policy ran (unarmed): the P2 shape, no fields */
    VERDICT_ALLOWED = 0, /* an author ran and did not refuse the call */
    VERDICT_DENIED = 1,  /* an author refused the call */
};

struct row {
    int kind;
    char ts[40];
    long turn;     /* ROW_CALL: the decode turn that observed the call */
    char *call_id; /* ROW_CALL: the join key — never a name, never a position */
    char *true_name;
    char *args;    /* raw in memory; bounded (marked) at write */
    int pending;
    char *outcome; /* raw in memory; NULL until the join fires */
    /* P3/P5 policy fields (VERDICT_NONE renders none of them — honesty rule) */
    int verdict;
    char *author;       /* the ONE author that refused / the authors that ran */
    char *refusal_name; /* the by-name refusal (P3's, or P5's) */
    char *reason;      /* raw in memory; bounded at write */
    char *denial_text; /* raw in memory; bounded at write */
    long turns_served;      /* ROW_EXIT */
    size_t *unresolved_idx; /* ROW_EXIT: indices of still-pending rows */
    size_t n_unresolved;
    /* P5's denial-rate instrument: the per-turn tally (ROW_TURNSTATS) and the
     * run aggregate (ROW_EXIT).  reasons_json is host-authored (never model
     * text), pre-rendered so log_flush stays a pure writer. */
    size_t t_calls, t_denied, t_allowed;
    char *reasons_json;
};

static struct row *g_rows;
static size_t g_nrows, g_rowcap;
static const char *g_log_path;

static struct row *row_alloc(void) {
    if (g_nrows == g_rowcap) {
        g_rowcap = g_rowcap ? g_rowcap * 2 : 16;
        g_rows = realloc(g_rows, g_rowcap * sizeof *g_rows);
        if (!g_rows) die_errno("realloc rows");
    }
    struct row *r = &g_rows[g_nrows++];
    memset(r, 0, sizeof *r);
    return r;
}

/* Rewrite the whole log atomically (temp beside the log + fsync + rename).
 * The proxy is the file's SINGLE writer, so a reader never sees a torn
 * state.  A failed flush is fatal: a record that silently stops is the one
 * failure mode this seat must never have. */
static void log_flush(void) {
    if (!g_log_path) return;
    size_t plen = strlen(g_log_path);
    char *tmp = xmalloc(plen + 5);
    snprintf(tmp, plen + 5, "%s.tmp", g_log_path);
    FILE *f = fopen(tmp, "w");
    if (!f) die_errno("cannot write the one log");
    for (size_t i = 0; i < g_nrows; i++) {
        const struct row *r = &g_rows[i];
        if (r->kind == ROW_CALL) {
            /* call_id renders VERBATIM — it is THE JOIN KEY, not free text
             * (stated P2-fix decision, bounding exemption (b)): a
             * marker-truncated key is a DIFFERENT key, and every consumer
             * re-joins this log by call_id (P9's reporter, the audit, P8's
             * replay).  Its length is transitively bounded by FH_FRAME_MAX
             * (it cannot exceed the frame it arrived in), and the in-memory
             * join always compares the full id.  The gate asserts the
             * exemption (bound phase: call_id verbatim while true_name is
             * marked), so it is a decision, not an oversight.  true_name,
             * args and outcome ARE model-controlled free text: capped with
             * the explicit marker, never silent. */
            char *jid = json_str(r->call_id);
            char *bname = bound_copy(r->true_name);
            char *jname = json_str(bname);
            char *bargs = bound_copy(r->args);
            char *jargs = json_str(bargs);
            char *bout = r->outcome ? bound_copy(r->outcome) : NULL;
            char *jout = bout ? json_str(bout) : NULL;
            fprintf(f,
                    "{\"ts\":\"%s\",\"session\":null,\"run\":null,"
                    "\"turn\":%ld,\"call_id\":%s,\"true_name\":%s,"
                    "\"args\":%s,\"pending\":%s,\"outcome\":%s",
                    r->ts, r->turn, jid, jname, jargs,
                    r->pending ? "true" : "false",
                    jout ? jout : "null");
            /* P3/P5: the verdict fields render ONLY when a policy actually ran
             * (the brief's honesty rule).  `author` names what ran — the
             * placeholder denylist and/or the justification check — never the
             * P6/P7 authors that do not exist yet; on a denial it names the
             * ONE author that refused, and refusal_name is the by-name
             * refusal (P3's denied-by-denylist, or P5's
             * absent-/malformed-justification).  reason/denial_text are real
             * exactly for a denial, explicit nulls otherwise. */
            if (r->verdict == VERDICT_DENIED) {
                char *breason = bound_copy(r->reason);
                char *jreason = json_str(breason);
                char *bdeny = bound_copy(r->denial_text);
                char *jdeny = json_str(bdeny);
                char *jauth = json_str(r->author ? r->author : FH_AUTHOR_DENYLIST);
                char *jref =
                    json_str(r->refusal_name ? r->refusal_name : FH_REFUSAL_DENYLIST);
                fprintf(f,
                        ",\"verdict\":\"denied\",\"author\":%s,"
                        "\"refusal_name\":%s,\"reason\":%s,"
                        "\"denial_text\":%s}",
                        jauth, jref, jreason, jdeny);
                free(breason);
                free(jreason);
                free(bdeny);
                free(jdeny);
                free(jauth);
                free(jref);
            } else if (r->verdict == VERDICT_ALLOWED) {
                char *jauth = json_str(r->author ? r->author : FH_AUTHOR_DENYLIST);
                fprintf(f,
                        ",\"verdict\":\"allowed\",\"author\":%s,"
                        "\"refusal_name\":null,\"reason\":null,"
                        "\"denial_text\":null}",
                        jauth);
                free(jauth);
            } else {
                fputc('}', f); /* VERDICT_NONE: the P2 row, byte-identical */
            }
            fputc('\n', f);
            free(jid);
            free(bname);
            free(jname);
            free(bargs);
            free(jargs);
            free(bout);
            free(jout);
        } else if (r->kind == ROW_TURNSTATS) {
            /* P5's denial-rate instrument: one row per armed turn, so the
             * dead-agent shape (every call denied, nothing executing, every
             * line looking protective) is a NUMBER in the record instead of
             * something an operator has to infer from a wall of denials.
             * denial_rate is null when the turn made no calls — "0.0000" would
             * be a claim about a sample that does not exist. */
            fprintf(f,
                    "{\"ts\":\"%s\",\"type\":\"turn-stats\",\"turn\":%ld,"
                    "\"calls\":%zu,\"denied\":%zu,\"allowed\":%zu,"
                    "\"denial_rate\":",
                    r->ts, r->turn, r->t_calls, r->t_denied, r->t_allowed);
            if (r->t_calls == 0) fputs("null", f);
            else fprintf(f, "%.4f", (double)r->t_denied / (double)r->t_calls);
            fprintf(f, ",\"denial_reasons\":%s}\n",
                    r->reasons_json ? r->reasons_json : "{}");
        } else if (r->kind == ROW_ANOM_UNJOINED || r->kind == ROW_ANOM_ECHO ||
                   r->kind == ROW_ANOM_UNRESOLVED_SUBST) {
            /* telemetry rows (P3): the record keeps the evidence; they are
             * instruments, not teeth — the enforcement is the name rewrite */
            char *jid = json_str(r->call_id); /* the key: verbatim, as above */
            char *bout = bound_copy(r->outcome);
            char *jout = json_str(bout);
            if (r->kind == ROW_ANOM_UNRESOLVED_SUBST) {
                fprintf(f,
                        "{\"ts\":\"%s\",\"type\":\"unresolved-substitution\","
                        "\"turn\":%ld,\"call_id\":%s,\"true_name\":%s}\n",
                        r->ts, r->turn, jid, jout);
            } else {
                fprintf(f,
                        "{\"ts\":\"%s\",\"type\":\"%s\",\"turn\":%ld,"
                        "\"call_id\":%s,\"output\":%s}\n",
                        r->ts,
                        r->kind == ROW_ANOM_UNJOINED ? "unjoined-output"
                                                     : "echo-anomaly",
                        r->turn, jid, jout);
            }
            free(jid);
            free(bout);
            free(jout);
        } else {
            fprintf(f,
                    "{\"ts\":\"%s\",\"type\":\"proxy-exit\","
                    "\"turns_served\":%ld,\"unresolved\":[",
                    r->ts, r->turns_served);
            for (size_t k = 0; k < r->n_unresolved; k++) {
                const struct row *c = &g_rows[r->unresolved_idx[k]];
                char *jid = json_str(c->call_id); /* the key: verbatim, as above */
                char *bname = bound_copy(c->true_name);
                char *jname = json_str(bname);
                fprintf(f, "%s{\"call_id\":%s,\"turn\":%ld,\"true_name\":%s}",
                        k ? "," : "", jid, c->turn, jname);
                free(jid);
                free(bname);
                free(jname);
            }
            fputc(']', f);
            /* P5: the run aggregate, rendered ONLY when a policy ran — the
             * unarmed exit row stays byte-identical to P2's. */
            if (r->reasons_json) {
                fprintf(f,
                        ",\"calls_total\":%zu,\"denied_total\":%zu,"
                        "\"allowed_total\":%zu,\"all_denied\":%s,"
                        "\"denial_reasons\":%s",
                        r->t_calls, r->t_denied, r->t_allowed,
                        (r->t_calls > 0 && r->t_denied == r->t_calls) ? "true"
                                                                     : "false",
                        r->reasons_json);
            }
            fprintf(f, "}\n");
        }
    }
    if (fflush(f) != 0 || fsync(fileno(f)) != 0) die_errno("fsync the one log");
    if (fclose(f) != 0) die_errno("close the one log");
    if (rename(tmp, g_log_path) != 0) die_errno("rename the one log");
    free(tmp);
}

/* Append a call row: pending:true at write time, by definition — nothing has
 * answered it yet.  verdict is VERDICT_NONE when no policy ran (the P2
 * shape); author/refusal_name/reason/denial_text are owned by the row when a
 * policy refused it, and author is the joined set of authors that RAN on an
 * allowed row (never one that did not run). */
static void row_call_append(const char *call_id, const char *name,
                            const char *args, long turn, int verdict,
                            const char *author, const char *refusal_name,
                            const char *reason, const char *denial_text) {
    struct row *r = row_alloc();
    now_ts(r->ts, sizeof r->ts);
    r->kind = ROW_CALL;
    r->turn = turn;
    r->call_id = xstrdup(call_id);
    r->true_name = xstrdup(name ? name : "");
    r->args = xstrdup(args ? args : "");
    r->pending = 1;
    r->verdict = verdict;
    r->author = xstrdup(author ? author : FH_AUTHOR_DENYLIST);
    r->refusal_name = xstrdup(refusal_name ? refusal_name : "");
    r->reason = xstrdup(reason ? reason : "");
    r->denial_text = xstrdup(denial_text ? denial_text : "");
    log_flush();
}

/* Append a P3 telemetry row (unjoined-output / echo-anomaly): the record
 * keeps the evidence; these are instruments, never a stop. */
static void row_anom_append(int kind, const char *call_id, const char *output,
                            long turn) {
    struct row *r = row_alloc();
    now_ts(r->ts, sizeof r->ts);
    r->kind = kind;
    r->turn = turn;
    r->call_id = xstrdup(call_id);
    r->outcome = xstrdup(output ? output : "");
    r->verdict = VERDICT_NONE;
    log_flush();
}

/* The JOIN: a request frame carried a function_call_output whose call_id
 * matches a pending row — attach the outcome (raw; bounded at write) and
 * mark the row resolved.  The OLDEST pending row wins: one output answers
 * one call, even when a canned upstream replays the same call_id on a later
 * turn.  An output matching NO pending row is noted on stderr; its anomaly
 * row is P9's (unjoined-output), not this slice's. */
#ifndef FH_MUTANT_NO_JOIN /* the mutant compiles the join out entirely */
static void row_resolve(const char *call_id, const char *output, long turn) {
    for (size_t i = 0; i < g_nrows; i++) {
        struct row *r = &g_rows[i];
        if (r->kind != ROW_CALL || !r->pending) continue;
        if (strcmp(r->call_id, call_id) != 0) continue;
        r->pending = 0;
        r->outcome = xstrdup(output ? output : "");
        log_flush();
        note("turn %ld: joined call_id=%s (true_name=%s) -> outcome recorded",
             turn, call_id, r->true_name);
        return;
    }
    note("turn %ld: function_call_output for call_id=%s matches NO pending "
         "row (unjoined or an old replay; a NO-decoded-call output is an "
         "unjoined-output telemetry row in the outbound pass)",
         turn, call_id);
}
#endif /* FH_MUTANT_NO_JOIN */

/* THE DENIAL-RATE INSTRUMENT (P5) — one row per ARMED turn: calls, denied,
 * allowed and the denial-reason breakdown, plus a stderr line, plus the loud
 * 100%-denied line.  WHY IT EXISTS: a required-justification schema the model
 * cannot satisfy does not break anything visibly — every call is denied,
 * nothing executes, every log line looks protective, and the agent is
 * EFFECTIVELY DEAD.  A gate (or an operator) that only checks "denials happen"
 * cannot see that shape; a per-turn rate can.  The instrument is only rendered
 * when a policy ran (the honesty rule) and has its own mutation blind. */
static void turn_stats_emit(long turn) {
#ifdef FH_MUTANT_NO_DENIAL_RATE
    (void)turn; /* P5 MUTATION BLIND (build/fx-hostgate-nodrate): the
                 * instrument is compiled out, so the dead-agent shape becomes
                 * INVISIBLE in the record while every denial still happens —
                 * the gate's instrument phase must catch exactly that. */
    return;
#else
    if (!policy_armed()) return;
    size_t calls = 0, denied = 0, allowed = 0;
    const char *names[8];
    size_t counts[8];
    size_t n_names = 0;
    for (size_t i = 0; i < g_nrows; i++) {
        const struct row *r = &g_rows[i];
        if (r->kind != ROW_CALL || r->turn != turn) continue;
        calls++;
        if (r->verdict == VERDICT_DENIED) {
            denied++;
            const char *nm = (r->refusal_name && *r->refusal_name)
                                 ? r->refusal_name
                                 : "(unnamed refusal)";
            size_t k = 0;
            for (; k < n_names; k++) {
                if (strcmp(names[k], nm) == 0) {
                    counts[k]++;
                    break;
                }
            }
            if (k == n_names && n_names < 8) {
                names[n_names] = nm;
                counts[n_names] = 1;
                n_names++;
            }
        } else {
            allowed++;
        }
    }
    struct row *r = row_alloc();
    now_ts(r->ts, sizeof r->ts);
    r->kind = ROW_TURNSTATS;
    r->turn = turn;
    r->t_calls = calls;
    r->t_denied = denied;
    r->t_allowed = allowed;
    r->reasons_json = reasons_breakdown_json(names, counts, n_names);
    log_flush();

    char *reasons = reasons_breakdown_json(names, counts, n_names);
    if (calls == 0) {
        note("turn %ld: call stats: 0 call(s) (nothing to deny)", turn);
    } else {
        note("turn %ld: call stats: %zu call(s), %zu denied, %zu allowed "
             "(reasons %s)",
             turn, calls, denied, allowed, reasons);
        if (denied == calls) {
            note("turn %ld: DENIAL RATE 100%% — every call this turn was "
                 "denied (%s): nothing executed, so the agent is EFFECTIVELY "
                 "DEAD while the log looks protective.  This line is the "
                 "instrument; the shape is not a working gate, it is a broken "
                 "lane (an unsatisfiable schema, a policy that denies "
                 "everything, or a catalogue the model cannot satisfy)",
                 turn, reasons);
        }
    }
    free(reasons);
#endif /* FH_MUTANT_NO_DENIAL_RATE */
}

/* Exit report — THE VISIBILITY CONTRACT.  Every row still pending at exit is
 * (a) named on stderr and (b) listed in a terminal proxy-exit summary row, so
 * an unfireable join is loud in the record instead of a missing outcome half
 * that could be mistaken for a record hole.  P5 adds the RUN aggregate of the
 * denial-rate instrument (and the loud all-denied line) to the same row. */
static void log_exit_report(long turns_served) {
    size_t n_unres = 0, n_calls = 0;
    for (size_t i = 0; i < g_nrows; i++) {
        if (g_rows[i].kind != ROW_CALL) continue; /* exit/telemetry rows */
        n_calls++;
        if (g_rows[i].pending) n_unres++;
    }
    if (n_unres > 0) {
        note("UNRESOLVED: %zu call(s) were decoded but never answered by any "
             "function_call_output before exit:", n_unres);
        for (size_t i = 0; i < g_nrows; i++) {
            const struct row *r = &g_rows[i];
            if (r->kind == ROW_CALL && r->pending) {
                note("  call_id=%s true_name=%s turn=%ld",
                     r->call_id, r->true_name, r->turn);
            }
        }
    } else if (n_calls > 0) {
        note("join: all %zu recorded call(s) resolved", n_calls);
    }

#ifndef FH_MUTANT_NO_DENIAL_RATE
    /* The run aggregate (only when a policy ran AND the instrument exists:
     * FH_MUTANT_NO_DENIAL_RATE removes the WHOLE instrument — per-turn rows,
     * exit-row fields and stderr lines — so "the instrument is gone" is one
     * property the gate can assert, not a half-removed one). */
    size_t denied = 0, allowed = 0;
    const char *names[8];
    size_t counts[8];
    size_t n_names = 0;
    int instrument = policy_armed();
    if (instrument) {
        for (size_t i = 0; i < g_nrows; i++) {
            const struct row *r = &g_rows[i];
            if (r->kind != ROW_CALL) continue;
            if (r->verdict == VERDICT_DENIED) {
                denied++;
                const char *nm = (r->refusal_name && *r->refusal_name)
                                     ? r->refusal_name
                                     : "(unnamed refusal)";
                size_t k = 0;
                for (; k < n_names; k++) {
                    if (strcmp(names[k], nm) == 0) {
                        counts[k]++;
                        break;
                    }
                }
                if (k == n_names && n_names < 8) {
                    names[n_names] = nm;
                    counts[n_names] = 1;
                    n_names++;
                }
            } else {
                allowed++;
            }
        }
    }
#else
    /* P5 MUTATION BLIND (build/fx-hostgate-nodrate): the whole instrument is
     * compiled out, so the dead-agent shape leaves NO trace in the record or
     * on stderr while every denial still happens — exactly the blindness this
     * instrument exists to remove, and what the gate's instrument phase
     * catches.  Said out loud, so the mutant is not mistaken for a build that
     * merely has nothing to report. */
    if (policy_armed())
        note("denial-rate instrument: COMPILED OUT (FH_MUTANT_NO_DENIAL_RATE) "
             "— the dead-agent shape is NOT reported: no turn-stats rows, no "
             "exit aggregate, no 100%%-denied line");
#endif

    struct row *r = row_alloc();
    now_ts(r->ts, sizeof r->ts);
    r->kind = ROW_EXIT;
    r->turns_served = turns_served;
    r->unresolved_idx = xmalloc(n_unres * sizeof *r->unresolved_idx);
    size_t k = 0;
    for (size_t i = 0; i < g_nrows - 1; i++) {
        if (g_rows[i].kind == ROW_CALL && g_rows[i].pending) {
            r->unresolved_idx[k++] = i;
        }
    }
    r->n_unresolved = n_unres;
#ifndef FH_MUTANT_NO_DENIAL_RATE
    if (instrument) {
        r->t_calls = n_calls;
        r->t_denied = denied;
        r->t_allowed = allowed;
        r->reasons_json = reasons_breakdown_json(names, counts, n_names);
    }
#endif
    log_flush();

#ifndef FH_MUTANT_NO_DENIAL_RATE
    if (instrument) {
        char *reasons = reasons_breakdown_json(names, counts, n_names);
        note("denial rate: %zu of %zu call(s) denied, %zu allowed (reasons %s)",
             denied, n_calls, allowed, reasons);
        if (n_calls > 0 && denied == n_calls) {
            note("ALL %zu call(s) DENIED — the agent is EFFECTIVELY DEAD: "
                 "nothing executed in this whole run while every line above "
                 "looks protective (see the per-turn 'DENIAL RATE 100%%' "
                 "lines and the per-turn denial reasons)",
                 n_calls);
        }
        free(reasons);
    }
#endif
}

/* ── the decode gate + the outbound substitution (P3) ────────────────────── */

/* The pinned placeholder denylist (--deny NAME, repeatable).  EMPTY means
 * NO policy ran: nothing is rewritten, no verdict field is rendered (the
 * P2 shape, byte-identical). */
static const char **g_deny_list;
static size_t g_ndeny;
static const char *g_dump_path; /* --dump-requests: the model-facing frames */

/* P5's arm (--require-justification), declared HERE because policy_armed()
 * is what "a policy ran" means for the honesty rule below: with the
 * justification check armed, a policy DID run, so rows carry verdict fields
 * and the denial-rate instrument speaks. */
static int g_require_justify;

/* ARMED = an author that can refuse is active.  The denylist (P3) and the
 * justification check (P5) are two authors; either one alone is armed. */
static int policy_armed(void) { return g_ndeny > 0 || g_require_justify; }

static int policy_denied(const char *name) {
    if (!policy_armed() || !name) return 0;
    for (size_t i = 0; i < g_ndeny; i++) {
        if (strcmp(g_deny_list[i], name) == 0) return 1;
    }
    return 0;
}

/* THE DENY MAP — the per-run join state for BOTH rewrites, keyed by
 * call_id (never a name, never a position; call_id is never rewritten on
 * either leg, so the join is exact).  It persists ACROSS turns inside the
 * proxy.  (Rebuild-from-log at restart is slice P8's, not built here.) */
struct deny_key {
    char *call_id;
    char *true_name; /* what the outbound restore puts back */
    char *reason;    /* names the refusing author's reason */
    char *denial_text; /* what the outbound substitution writes over the sentinel */
    /* P3-fix: the pending-substitution instrument.  Every denied call_id MUST
     * be resolved by the NEXT request (its function_call_output substituted);
     * subst_pending stays 1 until that substitution actually fires, and
     * denied_turn scopes the window so an unresolved-at-turn-end denial can be
     * reported instead of sitting silent. */
    long denied_turn;
    int subst_pending;
};
static struct deny_key *g_dmap;
static size_t g_ndmap, g_dmapcap;

static struct deny_key *dmap_find(const char *call_id) {
    for (size_t i = 0; i < g_ndmap; i++) {
        if (strcmp(g_dmap[i].call_id, call_id) == 0) return &g_dmap[i];
    }
    return NULL;
}

static void dmap_put(const char *call_id, const char *true_name,
                     const char *reason, const char *denial_text, long turn) {
    struct deny_key *k = dmap_find(call_id);
    if (!k) {
        if (g_ndmap == g_dmapcap) {
            g_dmapcap = g_dmapcap ? g_dmapcap * 2 : 8;
            g_dmap = realloc(g_dmap, g_dmapcap * sizeof *g_dmap);
            if (!g_dmap) die_errno("realloc deny map");
        }
        k = &g_dmap[g_ndmap++];
        memset(k, 0, sizeof *k);
        k->call_id = xstrdup(call_id);
    }
    free(k->true_name);
    free(k->reason);
    free(k->denial_text);
    k->true_name = xstrdup(true_name);
    k->reason = xstrdup(reason);
    k->denial_text = xstrdup(denial_text);
    /* P3-fix: a (re)denial opens a fresh substitution window for this turn */
    k->denied_turn = turn;
    k->subst_pending = 1;
}

/* ── JSON rebuild primitives (yyjson has no doc->mut-doc here, so denied
 * events are re-serialized by walking the PARSED value and writing every
 * untouched part verbatim with yyjson_val_write — unknown keys included) ── */

/* A growable text buffer (the served stream and the rebuilt JSONs). */
struct tbuf {
    char *p;
    size_t len, cap;
};
static void tb_put(struct tbuf *t, const char *s, size_t n) {
    if (t->len + n + 1 > t->cap) {
        size_t nc = t->cap ? t->cap : 256;
        while (nc < t->len + n + 1) nc *= 2;
        char *np = realloc(t->p, nc);
        if (!np) die_errno("realloc tbuf");
        t->p = np;
        t->cap = nc;
    }
    memcpy(t->p + t->len, s, n);
    t->len += n;
    t->p[t->len] = '\0';
}
static void tb_puts(struct tbuf *t, const char *s) { tb_put(t, s, strlen(s)); }

/* The denial-reason breakdown as JSON, host-authored from the rows' own
 * refusal names (never model text, so no bounding applies).  Small and local:
 * the reasons are the closed set of refusal names this seat can emit. */
#ifndef FH_MUTANT_NO_DENIAL_RATE
static char *reasons_breakdown_json(const char *const *names, const size_t *counts,
                                    size_t n) {
    struct tbuf t = {0};
    tb_puts(&t, "{");
    for (size_t i = 0; i < n; i++) {
        char *jn = json_str(names[i]);
        if (i) tb_puts(&t, ",");
        tb_puts(&t, jn);
        char buf[32];
        snprintf(buf, sizeof buf, ":%zu", counts[i]);
        tb_puts(&t, buf);
        free(jn);
    }
    tb_puts(&t, "}");
    return t.p;
}
#endif /* FH_MUTANT_NO_DENIAL_RATE */

/* Serialize one parsed value verbatim (compact).  Dies on failure: a value
 * that parsed but will not serialize is a seat bug, not stream input. */
static void tb_put_val(struct tbuf *t, const yyjson_val *v) {
    size_t n = 0;
    char *s = yyjson_val_write_opts(v, 0, NULL, &n, NULL);
    if (!s) die_errno("serialize json value");
    tb_put(t, s, n);
    free(s);
}

/* Render `obj` as "{...}" with the string value at `key` REPLACED by
 * `newval` (added at the end if absent).  All other members verbatim.
 * (Rewrite machinery: unused in the pre-fix control build.) */
#ifndef FH_MUTANT_NO_REWRITE
static void tb_put_obj_strset(struct tbuf *t, const yyjson_val *obj,
                              const char *key, const char *newval) {
    tb_puts(t, "{");
    yyjson_val *k, *v;
    size_t idx, max;
    int seen = 0;
    yyjson_obj_foreach((yyjson_val *)obj, idx, max, k, v) {
        const char *kn = yyjson_get_str(k);
        if (idx > 0) tb_puts(t, ",");
        char *jk = json_str(kn ? kn : "");
        tb_puts(t, jk);
        free(jk);
        tb_puts(t, ":");
        if (kn && strcmp(kn, key) == 0) {
            seen = 1;
            char *jv = json_str(newval);
            tb_puts(t, jv);
            free(jv);
        } else {
            tb_put_val(t, v);
        }
    }
    if (!seen) {
        if (yyjson_obj_size((yyjson_val *)obj) > 0) tb_puts(t, ",");
        char *jk = json_str(key);
        char *jv = json_str(newval);
        tb_puts(t, jk);
        tb_puts(t, ":");
        tb_puts(t, jv);
        free(jk);
        free(jv);
    }
    tb_puts(t, "}");
}
#endif /* FH_MUTANT_NO_REWRITE */

/* ── P4: the reserved-name contract and the PINNED verb catalog ───────────── */

/* The reserved name (see the P3 header block): refused as unknown by the
 * verbs server even in an allow-all lane, so the backstop is structural.
 * The name is OVERRIDABLE only at BUILD time, for the gate's arms
 * (-DFH_RESERVED_NAME='"fx host denied"' / '"fx_write"'), the same
 * same-source discipline the -DFH_MUTANT_* builds use: a runtime knob here
 * would be a way to disarm the contract it is the point of. */
#ifndef FH_RESERVED_NAME
#define FH_RESERVED_NAME "fx_host_denied"
#endif

/* THE PINNED CATALOG — a HOST-SIDE MIRROR of the closed fx-verbs vocabulary,
 * harvested from the VERBS[] table in tools/fx-verbs-server.c:2321-2456 (the
 * proxy cannot read the guest source at run time; the GATE is what re-checks
 * this list against that table — `--print-catalog`).  One name per line, in
 * table order.  PINNED by sha256 over these exact bytes (fh_catalog_check),
 * so editing this text without re-pinning is loud rather than a quiet change
 * in what the collision check checks.  The invariant that binds this list to
 * the gate's independent copy: `--print-catalog | sha256sum`. */
static const char fh_verb_catalog[] =
    "fx_query\n"
    "fx_status\n"
    "fx_activate\n"
    "fx_rollback\n"
    "fx_what\n"
    "fx_why\n"
    "fx_store_verify\n"
    "fx_build\n"
    "fx_outcome\n"
    "fx_generation\n"
    "fx_read\n"
    "fx_write\n"
    "fx_ls\n";

/* The pin: sha256 (lowercase hex) over fh_verb_catalog's bytes, plus the
 * provenance of the bytes it pins.  RE-PIN after a catalog edit:
 *   build/fx-hostgate --print-catalog-sha
 * and put the printed value here (the refusal below names both shas, so a
 * stale pin diagnoses itself).  -DFH_CATALOG_SHA256 builds the gate's
 * bad-pin arm. */
#define FH_CATALOG_PROVENANCE "tools/fx-verbs-server.c:2321-2456 VERBS[]"
#ifndef FH_CATALOG_SHA256
#define FH_CATALOG_SHA256 \
    "6b97a08255734cfb5cead2e347a0197ce7582fd02d74b2a2e92327b74496bf7a"
#endif

/* validate_identifier's charset, MIRRORED (src/runner.c:49-70):
 * ^[A-Za-z0-9._-]+$ and not starting with '-'.  Mirrored on purpose — the
 * guest's rule IS the contract the reserved name must satisfy, and the proxy
 * must not "improve" it into a rule the guest does not enforce. */
#ifndef FH_MUTANT_NO_NAME_CONTRACT
static int fh_identifier_ok(const char *s) {
    if (!s || !*s) return 0;
    if (s[0] == '-') return 0;
    for (const char *p = s; *p; p++) {
        unsigned char c = (unsigned char)*p;
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
              (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-'))
            return 0;
    }
    return 1;
}

#endif /* FH_MUTANT_NO_NAME_CONTRACT */

/* Catalog accessors: count the lines; copy the idx-th name into buf. */
static size_t fh_catalog_count(void) {
    size_t n = 0;
    for (const char *p = fh_verb_catalog; *p; p++) {
        if (*p == '\n') n++;
    }
    return n;
}

static int fh_catalog_nth(size_t idx, char *buf, size_t cap) {
    size_t n = 0;
    const char *p = fh_verb_catalog;
    while (*p) {
        const char *e = strchr(p, '\n');
        if (!e) break;
        if (n == idx) {
            size_t len = (size_t)(e - p);
            if (len + 1 > cap) return 0;
            memcpy(buf, p, len);
            buf[len] = '\0';
            return 1;
        }
        n++;
        p = e + 1;
    }
    return 0;
}

/* THE CONTRACT CHECK — a STARTUP REFUSAL, loud and non-zero, before the slave
 * path is published: the three properties P4 exists to make checked.  A
 * refusal is the only honest output here; "the proxy ran but the reserved
 * name was callable" has no log line that could make it visible in time. */
static void fh_catalog_check(void) {
#ifdef FH_MUTANT_NO_NAME_CONTRACT
    /* P4 MUTATION BLIND (build/fx-hostgate-nonamecheck): the whole contract
     * is compiled OUT.  The gate's arms pair it with a colliding / bad-charset
     * reserved name, where the proxy STARTS and the colliding name is
     * CALLABLE — the silent allow the refusal exists to prevent. */
    note("P4 NAME CONTRACT: COMPILED OUT (FH_MUTANT_NO_NAME_CONTRACT) — the "
         "reserved name is NOT checked against the guest's charset or the "
         "pinned catalog; a collision would be a silent allow");
    return;
#else
    char got[65];
    sha256_hex(fh_verb_catalog, strlen(fh_verb_catalog), got);
    if (strcmp(got, FH_CATALOG_SHA256) != 0) {
        note("FATAL: the pinned verb catalog (%s) hashes to %s, but the "
             "compiled pin is %s — the catalog was edited without a re-pin, so "
             "the collision check would be checking bytes the pin does not "
             "describe.  RE-PIN (--print-catalog-sha) or restore the catalog; "
             "REFUSING TO START",
             FH_CATALOG_PROVENANCE, got, FH_CATALOG_SHA256);
        exit(1);
    }
    if (!fh_identifier_ok(FH_RESERVED_NAME)) {
        note("FATAL: the reserved name \"%s\" does NOT match the guest's "
             "validate_identifier charset ^[A-Za-z0-9._-]+$ (and must not start "
             "with '-' — src/runner.c:49-70): a name the guest cannot parse is "
             "not a reserved name; REFUSING TO START",
             FH_RESERVED_NAME);
        exit(1);
    }
    size_t n = fh_catalog_count();
    char name[128];
    for (size_t i = 0; i < n; i++) {
        if (!fh_catalog_nth(i, name, sizeof name)) continue;
        if (strcmp(name, FH_RESERVED_NAME) == 0) {
            note("FATAL: the reserved name \"%s\" COLLIDES with catalog verb "
                 "\"%s\" (%s) — a collision makes the reserved name CALLABLE "
                 "(an allow-all lane dispatches it and the verbs server "
                 "answers) = a SILENT ALLOW; REFUSING TO START",
                 FH_RESERVED_NAME, name, FH_CATALOG_PROVENANCE);
            exit(1);
        }
    }
    note("P4 name contract: reserved name \"%s\" passes the guest's identifier "
         "charset and collides with none of the %zu pinned catalog verb(s); "
         "catalog sha256 %.12s.. (pinned), %s",
         FH_RESERVED_NAME, n, got, FH_CATALOG_PROVENANCE);
#endif /* FH_MUTANT_NO_NAME_CONTRACT */
}

/* ── P5: the justification (the tools injection + the judgement) ──────────── */

/* --require-justification arms BOTH halves: the tools-array injection into the
 * forwarded request (the model is TOLD what is required) and the judgement at
 * item completion (the host CHECKS it).  The two are separable by mutation
 * (FH_MUTANT_NO_TOOLS_INJECT / FH_MUTANT_NO_JUSTIFY_CHECK) precisely because
 * each one failing in isolation looks different: no injection = the model was
 * never told and the agent dies unjustified; no check = the model was told and
 * the host ignored it.  (The flag itself, g_require_justify, is declared with
 * the denylist above, where policy_armed() lives; the author/refusal names are
 * declared at FH_AUTHOR_* / FH_REFUSAL_* beside the log writer.) */

enum { J_OK = 0, J_ABSENT = 1, J_MALFORMED = 2 };

/* The judgement of ONE call's justification, over the arguments the GUEST will
 * dispatch (the caller passes the delta-accumulated value; see the P5 header
 * block).  `why` receives a human reason that lands in the row and in the
 * denial text the model reads. */
#if !defined(FH_MUTANT_NO_JUSTIFY_CHECK) && !defined(FH_MUTANT_SINGLE_ITEM)
static int justification_verdict(const char *args, char *why, size_t whycap) {
    if (!args || !*args) {
        snprintf(why, whycap,
                 "the call carries no arguments, so it carries no "
                 "justification");
        return J_ABSENT;
    }
    yyjson_doc *doc = yyjson_read(args, strlen(args), 0);
    yyjson_val *root = doc ? yyjson_doc_get_root(doc) : NULL;
    if (!yyjson_is_obj(root)) {
        snprintf(why, whycap,
                 "the call's arguments are not a JSON object, so no "
                 "justification can be read from them");
        if (doc) yyjson_doc_free(doc);
        return J_MALFORMED;
    }
    yyjson_val *jv = yyjson_obj_get(root, "justification");
    if (!jv) {
        snprintf(why, whycap,
                 "the call's arguments carry no \"justification\" field (the "
                 "host injects the tools schema with justification REQUIRED)");
        yyjson_doc_free(doc);
        return J_ABSENT;
    }
    const char *js = yyjson_get_str(jv);
    if (!js) {
        snprintf(why, whycap,
                 "the call's \"justification\" is not a JSON string (it is a "
                 "%s)", yyjson_is_null(jv)   ? "null"
                     : yyjson_is_num(jv)     ? "number"
                     : yyjson_is_bool(jv)    ? "boolean"
                     : yyjson_is_arr(jv)     ? "array"
                     : yyjson_is_obj(jv)     ? "object"
                                             : "non-string value");
        yyjson_doc_free(doc);
        return J_MALFORMED;
    }
    int blank = 1;
    for (const char *p = js; *p; p++) {
        if (!isspace((unsigned char)*p)) {
            blank = 0;
            break;
        }
    }
    if (blank) {
        snprintf(why, whycap,
                 "the call's \"justification\" is blank (a blank justification "
                 "is not a justification)");
        yyjson_doc_free(doc);
        return J_MALFORMED;
    }
    yyjson_doc_free(doc);
    return J_OK;
}

#endif /* !FH_MUTANT_NO_JUSTIFY_CHECK && !FH_MUTANT_SINGLE_ITEM */

/* ONE call's verdict: the placeholder denylist (P3) first, then the
 * justification check (P5).  Returns 1 = DENY, 0 = allow; on DENY it fills the
 * refusing AUTHOR, the refusal NAME and the reason (which becomes the denial
 * text the model reads).  Every refusal is by name — never a bare rejection. */
#ifndef FH_MUTANT_SINGLE_ITEM /* only the per-item serve_stream judges */
static int call_judge(const char *name, const char *args,
                      const char **author_out, const char **refusal_out,
                      char *reason, size_t reason_cap) {
    if (policy_denied(name)) {
        snprintf(reason, reason_cap,
                 "\"%s\" is on the pinned host denylist (placeholder P3 "
                 "policy)", name);
        *author_out = FH_AUTHOR_DENYLIST;
        *refusal_out = FH_REFUSAL_DENYLIST;
        return 1;
    }
#ifndef FH_MUTANT_NO_JUSTIFY_CHECK
    if (g_require_justify) {
        char why[512];
        int j = justification_verdict(args, why, sizeof why);
        if (j == J_ABSENT) {
            snprintf(reason, reason_cap,
                     "\"%s\" was DENIED BY NAME absent-justification: %s", name,
                     why);
            *author_out = FH_AUTHOR_JUSTIFY;
            *refusal_out = FH_REFUSAL_ABSENT_JUSTIFY;
            return 1;
        }
        if (j == J_MALFORMED) {
            snprintf(reason, reason_cap,
                     "\"%s\" was DENIED BY NAME malformed-justification: %s",
                     name, why);
            *author_out = FH_AUTHOR_JUSTIFY;
            *refusal_out = FH_REFUSAL_MALFORMED_JUSTIFY;
            return 1;
        }
    }
#else
    /* P5 MUTATION BLIND (build/fx-hostgate-nojustify): the CHECK is compiled
     * out while --require-justification is still accepted and the tools array
     * is still injected.  An unjustified call is then judged by the denylist
     * alone and CROSSES VERBATIM — it executes.  That is the fail-open the
     * gate's justification arm must catch by the DISPATCH MARKER. */
    (void)args;
#endif
    return 0;
}

#endif /* FH_MUTANT_SINGLE_ITEM */

/* The AUTHOR field on an ALLOWED row: the authors that ACTUALLY RAN, joined.
 * A row claiming an author that did not run would be a record wider than the
 * evidence (the same rule that keeps P2 rows verdict-free). */
static const char *authors_ran(void) {
    if (g_ndeny > 0 && g_require_justify) return "denylist+justification";
    if (g_ndeny > 0) return FH_AUTHOR_DENYLIST;
    if (g_require_justify) return FH_AUTHOR_JUSTIFY;
    return "none";
}

/* THE INJECTED CATALOG — one tool per pinned verb, `justification` a REQUIRED
 * string property so the schema itself demands the claim.  Built from the same
 * fh_verb_catalog the collision check uses: one list, one provenance. */
#ifndef FH_MUTANT_NO_TOOLS_INJECT
static void tools_inject_json(struct tbuf *t) {
    tb_puts(t, "[");
    size_t n = fh_catalog_count();
    char name[128];
    for (size_t i = 0; i < n; i++) {
        if (!fh_catalog_nth(i, name, sizeof name)) continue;
        if (i) tb_puts(t, ",");
        tb_puts(t, "{\"type\":\"function\",\"name\":\"");
        tb_puts(t, name);
        tb_puts(t,
                "\",\"description\":\"hostgate: a pinned fx-verbs catalog "
                "entry; the host judges the call AND its justification before "
                "anything runs\",\"parameters\":{\"type\":\"object\","
                "\"properties\":{\"justification\":{\"type\":\"string\","
                "\"description\":\"REQUIRED: why this call is being made "
                "(what it is for, and what it is expected to affect). A call "
                "without one is denied by name "
                "(absent-justification).\"}},\"required\":[\"justification\"],"
                "\"additionalProperties\":true}}");
    }
    tb_puts(t, "]");
}

#endif /* FH_MUTANT_NO_TOOLS_INJECT */
/* ── the decode gate: judge at item completion, rewrite the name ────────── */

#ifndef FH_MUTANT_NO_REWRITE /* the control build forwards even denied calls */
/* One SSE event's data JSON with obj.item.name set to `name`.  Returns a
 * malloc'd JSON text, or NULL when the shape is not an object with an item
 * (the caller decides what that means). */
static char *event_json_set_item_name(const char *data, size_t data_len,
                                      const char *name) {
    yyjson_doc *doc = yyjson_read(data, data_len, 0);
    if (!doc) return NULL;
    yyjson_val *root = yyjson_doc_get_root(doc);
    yyjson_val *item = yyjson_is_obj(root) ? yyjson_obj_get(root, "item") : NULL;
    if (!yyjson_is_obj(item)) {
        yyjson_doc_free(doc);
        return NULL;
    }
    struct tbuf t = {0};
    tb_puts(&t, "{");
    yyjson_val *k, *v;
    size_t idx, max;
    yyjson_obj_foreach((yyjson_val *)root, idx, max, k, v) {
        const char *kn = yyjson_get_str(k);
        if (idx > 0) tb_puts(&t, ",");
        char *jk = json_str(kn ? kn : "");
        tb_puts(&t, jk);
        free(jk);
        tb_puts(&t, ":");
        if (kn && strcmp(kn, "item") == 0) {
            tb_put_obj_strset(&t, item, "name", name);
        } else {
            tb_put_val(&t, v);
        }
    }
    tb_puts(&t, "}");
    yyjson_doc_free(doc);
    return t.p; /* ownership moves to the caller */
}
#endif /* FH_MUTANT_NO_REWRITE */

#ifndef FH_MUTANT_NO_REWRITE
/* The completed event: rewrite the name of every function_call item in
 * response.output whose call_id is in the deny map.  Returns malloc'd JSON
 * (the whole event data rebuilt), or NULL when nothing needed rewriting —
 * the caller then forwards the raw span verbatim. */
static char *event_json_rewrite_completed(const char *data, size_t data_len) {
    yyjson_doc *doc = yyjson_read(data, data_len, 0);
    if (!doc) return NULL;
    yyjson_val *root = yyjson_doc_get_root(doc);
    yyjson_val *resp = yyjson_is_obj(root) ? yyjson_obj_get(root, "response") : NULL;
    yyjson_val *output = yyjson_is_obj(resp) ? yyjson_obj_get(resp, "output") : NULL;
    yyjson_val *it, *k, *v;
    size_t i, max, idx, ridx, rmax;
    int any = 0;
    if (yyjson_is_arr(output)) {
        yyjson_arr_foreach(output, i, max, it) {
            const char *ty = yyjson_is_obj(it)
                ? yyjson_get_str(yyjson_obj_get(it, "type")) : NULL;
            const char *cid = yyjson_is_obj(it)
                ? yyjson_get_str(yyjson_obj_get(it, "call_id")) : NULL;
            if (ty && strcmp(ty, "function_call") == 0 && cid && dmap_find(cid)) {
                any = 1;
                break;
            }
        }
    }
    if (!any) {
        yyjson_doc_free(doc);
        return NULL;
    }
    struct tbuf arr = {0};
    tb_puts(&arr, "[");
    yyjson_arr_foreach(output, i, max, it) {
        if (i > 0) tb_puts(&arr, ",");
        const char *ty = yyjson_is_obj(it)
            ? yyjson_get_str(yyjson_obj_get(it, "type")) : NULL;
        const char *cid = yyjson_is_obj(it)
            ? yyjson_get_str(yyjson_obj_get(it, "call_id")) : NULL;
        if (ty && strcmp(ty, "function_call") == 0 && cid && dmap_find(cid)) {
            tb_put_obj_strset(&arr, it, "name", FH_RESERVED_NAME);
        } else {
            tb_put_val(&arr, it);
        }
    }
    tb_puts(&arr, "]");
    /* response with output -> the rebuilt array, other members verbatim */
    struct tbuf robj = {0};
    tb_puts(&robj, "{");
    yyjson_obj_foreach((yyjson_val *)resp, ridx, rmax, k, v) {
        const char *kn = yyjson_get_str(k);
        if (ridx > 0) tb_puts(&robj, ",");
        char *jk = json_str(kn ? kn : "");
        tb_puts(&robj, jk);
        free(jk);
        tb_puts(&robj, ":");
        if (kn && strcmp(kn, "output") == 0) tb_put(&robj, arr.p, arr.len);
        else tb_put_val(&robj, v);
    }
    tb_puts(&robj, "}");
    free(arr.p);
    /* root with response -> the rebuilt object, other members verbatim */
    struct tbuf t = {0};
    tb_puts(&t, "{");
    yyjson_obj_foreach((yyjson_val *)root, idx, max, k, v) {
        const char *kn = yyjson_get_str(k);
        if (idx > 0) tb_puts(&t, ",");
        char *jk = json_str(kn ? kn : "");
        tb_puts(&t, jk);
        free(jk);
        tb_puts(&t, ":");
        if (kn && strcmp(kn, "response") == 0) tb_put(&t, robj.p, robj.len);
        else tb_put_val(&t, v);
    }
    tb_puts(&t, "}");
    free(robj.p);
    yyjson_doc_free(doc);
    return t.p;
}
#endif /* FH_MUTANT_NO_REWRITE */

/* ── the decode gate: serve one stream, judging every call item ────────────
 *
 * THE SERVED STREAM IS TRANSFORMED, NOT OBSERVED (this replaces P2's
 * decode_observe; the row-writing point is unchanged — item completion).
 * Every complete SSE event is forwarded with its RAW BYTES unless a deny
 * rewrites it, so an unarmed or all-accepted run is BYTE-IDENTICAL to the
 * upstream (the P1 transparency property the gate's phases 1-2 assert).
 *
 * A function_call output-item is BUFFERED WHOLE — added .. done — and the
 * proxy judges at ITEM COMPLETION with the accumulator's name in hand (the
 * name taken from the ADDED event, which is the ONLY name the guest's
 * accumulator ever sees — openai_responses.c:153-157) and NOTHING executed.
 * Accepted -> buffered bytes verbatim.  Denied -> the item's events are
 * re-emitted with item.name -> FH_RESERVED_NAME in the added and done
 * events (args deltas and call_id VERBATIM), the deny map gains the call,
 * and the row records the verdict.  The added event is THE load-bearing
 * rewrite: miss it and the guest accumulates and dispatches the true name —
 * a silent allow (the gate's completeness mutant removes exactly it). */
#ifndef FH_MUTANT_NO_REWRITE /* the pre-fix control never rewrites */
static void item_emit_rewritten(struct tbuf *out, const unsigned char *ib,
                                size_t ilen, long turn) {
    /* re-walk the buffered events; rewrite ONLY the two name-carrying ones */
    char event[128] = "";
    char *data = NULL;
    size_t data_len = 0, data_cap = 0;
    int have_event = 0, have_data = 0;
    size_t i = 0, ev_start = 0;
    while (i < ilen) {
        size_t start = i;
        while (i < ilen && ib[i] != '\n') i++;
        size_t stop = i;
        if (i < ilen) i++;
        size_t ll = stop - start;
        if (ll > 0 && ib[start + ll - 1] == '\r') ll--;
        if (ll == 0) { /* dispatch */
            if (have_event && have_data) {
                data[data_len] = '\0';
                int rewrite = 0;
                if (strcmp(event, "response.output_item.added") == 0) {
#ifdef FH_MUTANT_NO_ADDED_REWRITE
                    /* P3 COMPLETENESS MUTATION BLIND (build/fx-hostgate-
                     * blindadd): ONLY the added-event rewrite is compiled
                     * out; done and completed keep theirs.  The guest's
                     * accumulator is fed by the added event alone, so it
                     * accumulates and dispatches the TRUE name while the
                     * record claims a denial — a partial rewriter is an
                     * allow, and the gate must catch it by the dispatch
                     * marker on exactly this fixture. */
                    rewrite = 0;
#else
                    rewrite = 1;
#endif
                } else if (strcmp(event, "response.output_item.done") == 0) {
                    rewrite = 1;
                }
                if (rewrite) {
                    char *json = event_json_set_item_name(data, data_len,
                                                          FH_RESERVED_NAME);
                    if (!json) {
                        /* FAIL-CLOSED: a denied call whose event cannot be
                         * rewritten must NOT forward the true name — refuse
                         * the whole stream loudly (the guest sees a
                         * truncation-shaped EOF and ends its turn; loud,
                         * never a silent allow). */
                        note("turn %ld: FATAL: cannot rewrite a denied "
                             "item's '%s' event; refusing to forward the "
                             "true name", turn, event);
                        exit(1);
                    }
                    tb_puts(out, "event: ");
                    tb_puts(out, event);
                    tb_puts(out, "\ndata: ");
                    tb_puts(out, json);
                    tb_puts(out, "\n\n");
                    free(json);
                } else {
                    tb_put(out, (const char *)ib + ev_start, i - ev_start);
                }
            }
            event[0] = '\0';
            have_event = have_data = 0;
            data_len = 0;
            ev_start = i;
            continue;
        }
        const char *line = (const char *)ib + start;
        if (ll > 6 && memcmp(line, "event:", 6) == 0) {
            size_t v = 6;
            while (v < ll && (line[v] == ' ' || line[v] == '\t')) v++;
            size_t take = ll - v;
            if (take >= sizeof event) take = sizeof event - 1;
            memcpy(event, line + v, take);
            event[take] = '\0';
            have_event = 1;
        } else if (ll > 5 && memcmp(line, "data:", 5) == 0) {
            size_t v = 5;
            while (v < ll && (line[v] == ' ' || line[v] == '\t')) v++;
            size_t take = ll - v;
            if (data_len + take + 2 > FH_FRAME_MAX) {
                note("turn %ld: SSE data exceeds the frame cap; event kept raw",
                     turn);
            } else {
                if (data_len + take + 2 > data_cap) {
                    data_cap = (data_len + take + 2) * 2;
                    data = realloc(data, data_cap);
                    if (!data) die_errno("realloc sse data");
                }
                if (have_data) data[data_len++] = '\n';
                memcpy(data + data_len, line + v, take);
                data_len += take;
                have_data = 1;
            }
        }
    }
    /* an unterminated tail inside the buffer: raw (the guest never
     * dispatches an event without its blank line) */
    if (ev_start < ilen) tb_put(out, (const char *)ib + ev_start, ilen - ev_start);
    free(data);
}
#endif /* FH_MUTANT_NO_REWRITE */

#ifndef FH_MUTANT_SINGLE_ITEM /* only the per-item serve_stream uses these */
/* ── per-item open-item buffering (P3-fix) ────────────────────────────────
 *
 * One OPEN function_call item: its buffered raw events (added .. done) and
 * the identity captured from its added event.  item.id is the routing key
 * for argument deltas (which carry item_id, not call_id); call_id is the
 * join key; name is what the guest's accumulator would hold.
 *
 * P5 adds `args`: the ARGUMENT FRAGMENTS joined in arrival order, which is
 * what the GUEST dispatches (openai_responses.c:171-194 — the deltas are
 * authoritative, the done event's own `arguments` is used only when no delta
 * arrived at all).  The justification is judged on THESE bytes, so the host
 * judges the call the guest is about to make, not a field of the same item
 * that the guest may never read. */

struct open_item {
    char *item_id;
    char *call_id;
    char *name;
    struct tbuf ev;
    struct tbuf args; /* the guest's accumulator, mirrored */
    struct open_item *next;
};

static struct open_item *open_item_new(const char *item_id, const char *call_id,
                                       const char *name) {
    struct open_item *o = xmalloc(sizeof *o);
    memset(o, 0, sizeof *o);
    o->item_id = item_id ? xstrdup(item_id) : NULL;
    o->call_id = call_id ? xstrdup(call_id) : NULL;
    o->name = name ? xstrdup(name) : NULL;
    return o;
}

static void open_item_free(struct open_item *o) {
    free(o->item_id);
    free(o->call_id);
    free(o->name);
    free(o->ev.p);
    free(o->args.p);
    free(o);
}

static struct open_item *open_item_find_iid(struct open_item *head,
                                            const char *item_id) {
    if (!item_id) return NULL;
    for (struct open_item *o = head; o; o = o->next)
        if (o->item_id && strcmp(o->item_id, item_id) == 0) return o;
    return NULL;
}

static struct open_item *open_item_find_cid(struct open_item *head,
                                            const char *call_id) {
    if (!call_id) return NULL;
    for (struct open_item *o = head; o; o = o->next)
        if (o->call_id && strcmp(o->call_id, call_id) == 0) return o;
    return NULL;
}

/* Append in INSERTION order so a stream-end flush of several still-open
 * items preserves the order their added events arrived in. */
static void open_item_push(struct open_item **head, struct open_item **tail,
                           struct open_item *o) {
    o->next = NULL;
    if (*tail) {
        (*tail)->next = o;
        *tail = o;
    } else {
        *head = *tail = o;
    }
}

static void open_item_remove(struct open_item **head, struct open_item **tail,
                             struct open_item *target) {
    struct open_item **pp = head;
    while (*pp && *pp != target) pp = &(*pp)->next;
    if (!*pp) return;
    *pp = target->next;
    if (*tail == target) {
        struct open_item *t = NULL;
        for (struct open_item *o = *head; o; o = o->next) t = o;
        *tail = t;
    }
}
#endif /* !FH_MUTANT_SINGLE_ITEM */

/* P3-FIX PRE-FIX CONTROL (build/fx-hostgate-singleitem,
 * FH_MUTANT_SINGLE_ITEM): the P2/P3-era SINGLE open-item accumulator,
 * pinned verbatim as the asymmetry arm.  Its interleave shape is the
 * reproduced silent allow — a second output_item.added arriving before the
 * first item's done is appended to the OPEN item's buffer while
 * pend_name/pend_cid keep the FIRST item's values, so the first done judges
 * BOTH items under the first item's identity.  The gate's interleave
 * control arms run this build and require exactly that (marker present,
 * mis-joined allowed row) — the shape the per-item serve_stream below
 * flips. */
#ifdef FH_MUTANT_SINGLE_ITEM
static unsigned char *serve_stream_legacy(const unsigned char *buf, size_t len,
                                          long turn, size_t *out_len) {
    struct tbuf out = {0};
    struct tbuf item = {0}; /* the open function_call item's raw events */
    int in_item = 0;
    char *pend_name = NULL, *pend_cid = NULL; /* the ADDED event's values */

    char event[128] = "";
    char *data = NULL;
    size_t data_len = 0, data_cap = 0;
    int have_event = 0, have_data = 0;

    size_t i = 0, ev_start = 0;
    while (i < len) {
        size_t start = i;
        while (i < len && buf[i] != '\n') i++;
        size_t stop = i; /* excludes '\n' */
        if (i < len) i++; /* consume it; at len this is the unterminated tail */
        size_t ll = stop - start;
        if (ll > 0 && buf[start + ll - 1] == '\r') ll--;

        if (ll == 0) { /* blank line: dispatch the accumulated event */
            if (have_event && have_data && data_len <= FH_FRAME_MAX) {
                data[data_len] = '\0';
                yyjson_doc *doc = yyjson_read(data, data_len, 0);
                yyjson_val *root = doc ? yyjson_doc_get_root(doc) : NULL;

                int fc_item_ev = 0;
                const char *fc_cid = NULL, *fc_nm = NULL, *fc_args = NULL;
                if (yyjson_is_obj(root)) {
                    yyjson_val *iov = yyjson_obj_get(root, "item");
                    const char *ty = yyjson_is_obj(iov)
                        ? yyjson_get_str(yyjson_obj_get(iov, "type")) : NULL;
                    if (ty && strcmp(ty, "function_call") == 0) {
                        fc_item_ev = 1;
                        fc_cid = yyjson_get_str(yyjson_obj_get(iov, "call_id"));
                        fc_nm = yyjson_get_str(yyjson_obj_get(iov, "name"));
                        fc_args = yyjson_get_str(yyjson_obj_get(iov, "arguments"));
                    }
                }

                if (in_item) {
                    tb_put(&item, (const char *)buf + ev_start, i - ev_start);
                    if (fc_item_ev &&
                        strcmp(event, "response.output_item.done") == 0) {
                        /* ITEM COMPLETION — the judge point.  The true name
                         * is the ADDED event's (what the guest's accumulator
                         * holds); fall back to done's if added lacked one. */
                        const char *nm = pend_name ? pend_name : fc_nm;
                        const char *cid = pend_cid ? pend_cid : fc_cid;
                        if (!cid || !*cid) {
                            /* no join key -> not recordable, not deniable;
                             * forward what came (P2's honest note) */
                            note("turn %ld: function_call item WITHOUT a "
                                 "call_id — not recorded, not joinable",
                                 turn);
                            tb_put(&out, item.p, item.len);
                        } else if (nm && policy_armed() &&
                                   policy_denied(nm)) {
                            char reason[512];
                            snprintf(reason, sizeof reason,
                                     "\"%s\" is on the pinned host denylist "
                                     "(placeholder P3 policy)", nm);
                            char *denial =
                                xmalloc(strlen(reason) + 64);
                            snprintf(denial, strlen(reason) + 64,
                                     "(denied by host policy: %s)", reason);
                            dmap_put(cid, nm, reason, denial, turn);
                            row_call_append(cid, nm, fc_args, turn,
                                            VERDICT_DENIED,
                                            FH_AUTHOR_DENYLIST,
                                            FH_REFUSAL_DENYLIST, reason,
                                            denial);
                            note("turn %ld: DENIED call_id=%s true_name=%s -> "
                                 "serving the reserved name",
                                 turn, cid, nm);
#ifdef FH_MUTANT_NO_REWRITE
                            /* P3 PRE-FIX CONTROL (build/fx-hostgate-norewrite):
                             * the P2-era behavior pinned — the enforcement
                             * rewrites are compiled out while the record
                             * still runs, so the stream carries the TRUE name
                             * of a call the log says was denied.  The gate's
                             * control arm proves the stub then DISPATCHES
                             * (marker present): the asymmetry the real proxy
                             * flips. */
                            tb_put(&out, item.p, item.len);
#else
                            item_emit_rewritten(&out,
                                                (const unsigned char *)item.p,
                                                item.len, turn);
#endif
                            free(denial);
                        } else {
                            row_call_append(cid, nm, fc_args, turn,
                                            policy_armed() ? VERDICT_ALLOWED
                                                           : VERDICT_NONE,
                                            policy_armed() ? authors_ran()
                                                           : NULL,
                                            NULL, NULL, NULL);
                            tb_put(&out, item.p, item.len); /* verbatim */
                        }
                        item.len = 0;
                        in_item = 0;
                        free(pend_name); pend_name = NULL;
                        free(pend_cid); pend_cid = NULL;
                    }
                } else if (fc_item_ev &&
                           strcmp(event, "response.output_item.added") == 0) {
                    /* the item OPENS: buffer whole from here (its events are
                     * HELD until completion — the stated latency price of
                     * judging BEFORE anything crosses) */
                    in_item = 1;
                    item.len = 0;
                    tb_put(&item, (const char *)buf + ev_start, i - ev_start);
                    pend_name = fc_nm ? xstrdup(fc_nm) : NULL;
                    pend_cid = fc_cid ? xstrdup(fc_cid) : NULL;
                } else if (strcmp(event, "response.completed") == 0 &&
                           yyjson_is_obj(root)) {
#ifdef FH_MUTANT_NO_REWRITE
                    tb_put(&out, (const char *)buf + ev_start,
                           i - ev_start); /* the control keeps even this */
#else
                    /* the completed event's output array is not read by
                     * today's guest — rewrite it anyway so the byte-level
                     * invariant holds against a guest that reads raw */
                    char *json = event_json_rewrite_completed(data, data_len);
                    if (json) {
                        tb_puts(&out, "event: response.completed\n");
                        tb_puts(&out, "data: ");
                        tb_puts(&out, json);
                        tb_puts(&out, "\n\n");
                        free(json);
                    } else {
                        tb_put(&out, (const char *)buf + ev_start,
                               i - ev_start);
                    }
#endif
                } else {
                    tb_put(&out, (const char *)buf + ev_start, i - ev_start);
                }
                if (doc) yyjson_doc_free(doc);
            } else {
                /* not a parseable event (no event+data pair, or over-cap):
                 * forward the raw span — the stream stays byte-identical */
                tb_put(&out, (const char *)buf + ev_start, i - ev_start);
            }
            event[0] = '\0';
            have_event = 0;
            have_data = 0;
            data_len = 0;
            ev_start = i;
            continue;
        }

        const char *line = (const char *)buf + start;
        if (ll > 6 && memcmp(line, "event:", 6) == 0) {
            size_t v = 6;
            while (v < ll && (line[v] == ' ' || line[v] == '\t')) v++;
            size_t take = ll - v;
            if (take >= sizeof event) take = sizeof event - 1;
            memcpy(event, line + v, take);
            event[take] = '\0';
            have_event = 1;
        } else if (ll > 5 && memcmp(line, "data:", 5) == 0) {
            size_t v = 5;
            while (v < ll && (line[v] == ' ' || line[v] == '\t')) v++;
            size_t take = ll - v;
            if (data_len + take + 2 > FH_FRAME_MAX) {
                note("turn %ld: SSE data exceeds the frame cap; event skipped",
                     turn);
                data_len = 0;
                have_data = 0;
            } else {
                if (data_len + take + 2 > data_cap) {
                    data_cap = (data_len + take + 2) * 2;
                    data = realloc(data, data_cap);
                    if (!data) die_errno("realloc sse data");
                }
                if (have_data) data[data_len++] = '\n';
                memcpy(data + data_len, line + v, take);
                data_len += take;
                have_data = 1;
            }
        }
    }

    if (in_item) {
        /* an item that never completed: NOTHING was judged, so there is no
         * verdict to enforce — forward the held bytes verbatim and say so
         * (loud; the alternative, dropping them, would be suppression) */
        note("turn %ld: function_call item did NOT complete before the stream "
             "ended — held events forwarded verbatim, unjudged",
             turn);
        tb_put(&out, item.p, item.len);
    }
    /* the unterminated tail: raw, byte-identical (the guest's parser never
     * dispatches an event without its blank line) */
    if (ev_start < len) tb_put(&out, (const char *)buf + ev_start, len - ev_start);
    free(data);
    free(item.p);
    free(pend_name);
    free(pend_cid);
    *out_len = out.len;
    return (unsigned char *)out.p;
}
#endif /* FH_MUTANT_SINGLE_ITEM */

/* ── the decode gate: serve one stream, per-item buffering (P3-fix) ─────────
 *
 * THE SERVED STREAM IS TRANSFORMED, NOT OBSERVED (this replaces P2's
 * decode_observe; the row-writing point is unchanged — item completion).
 * Every complete SSE event is forwarded with its RAW BYTES unless a deny
 * rewrites it, so an unarmed or all-accepted run is BYTE-IDENTICAL to the
 * upstream (the P1 transparency property the gate's phases 1-2 assert).
 *
 * A function_call output-item is BUFFERED WHOLE — added .. done — and the
 * proxy judges at ITEM COMPLETION with THAT item's OWN name/call_id/args
 * (the name taken from the ADDED event, which is the ONLY name the guest's
 * accumulator ever sees — openai_responses.c:153-157) and NOTHING executed.
 * Accepted -> buffered bytes verbatim.  Denied -> the item's events are
 * re-emitted with item.name -> FH_RESERVED_NAME in the added and done
 * events (args deltas and call_id VERBATIM), the deny map gains the call,
 * and the row records the verdict.  The added event is THE load-bearing
 * rewrite: miss it and the guest accumulates and dispatches the true name —
 * a silent allow (the gate's completeness mutant removes exactly it).
 *
 * PER-ITEM BUFFERING (THE FIX): the open items are a LIST keyed by item
 * identity (item.id), not a single accumulator.  When two calls INTERLEAVE
 * (added(A) -> added(B) -> delta(B) -> done(B) -> done(A)), each item is
 * held in its OWN buffer and judged at ITS OWN done with ITS OWN identity —
 * so a denied item's events are the only ones rewritten and an accepted
 * item's events are never rewritten.  Argument deltas carry item_id (not
 * call_id) and are matched to their item on that key.  An added arriving
 * while a DIFFERENT item is open is the exact shape that produced the
 * silent allow under the single accumulator; with per-item buffers it is
 * handled correctly, and the proxy says so LOUDLY — a silent merge here
 * must never be possible again.  response.completed is forwarded
 * immediately (NEVER routed into an open item's buffer) and must be the
 * LAST event; anything after it is noted loudly (the guest breaks its read
 * loop on completed, openai_responses.c:273-278). */
static unsigned char *serve_stream(const unsigned char *buf, size_t len,
                                   long turn, size_t *out_len) {
#ifdef FH_MUTANT_SINGLE_ITEM
    return serve_stream_legacy(buf, len, turn, out_len);
#else
    struct tbuf out = {0};
    struct open_item *open_head = NULL, *open_tail = NULL;
    int seen_completed = 0;

    char event[128] = "";
    char *data = NULL;
    size_t data_len = 0, data_cap = 0;
    int have_event = 0, have_data = 0;

    size_t i = 0, ev_start = 0;
    while (i < len) {
        size_t start = i;
        while (i < len && buf[i] != '\n') i++;
        size_t stop = i; /* excludes '\n' */
        if (i < len) i++; /* consume it; at len this is the unterminated tail */
        size_t ll = stop - start;
        if (ll > 0 && buf[start + ll - 1] == '\r') ll--;

        if (ll == 0) { /* blank line: dispatch the accumulated event */
            if (have_event && have_data && data_len <= FH_FRAME_MAX) {
                data[data_len] = '\0';
                yyjson_doc *doc = yyjson_read(data, data_len, 0);
                yyjson_val *root = doc ? yyjson_doc_get_root(doc) : NULL;

                int fc_item_ev = 0;
                const char *fc_iid = NULL, *fc_cid = NULL, *fc_nm = NULL,
                           *fc_args = NULL;
                const char *args_item_id = NULL;
                if (yyjson_is_obj(root)) {
                    yyjson_val *iov = yyjson_obj_get(root, "item");
                    const char *ty = yyjson_is_obj(iov)
                        ? yyjson_get_str(yyjson_obj_get(iov, "type")) : NULL;
                    if (ty && strcmp(ty, "function_call") == 0) {
                        fc_item_ev = 1;
                        fc_iid = yyjson_get_str(yyjson_obj_get(iov, "id"));
                        fc_cid = yyjson_get_str(yyjson_obj_get(iov, "call_id"));
                        fc_nm = yyjson_get_str(yyjson_obj_get(iov, "name"));
                        fc_args = yyjson_get_str(yyjson_obj_get(iov, "arguments"));
                    }
                    args_item_id = yyjson_get_str(yyjson_obj_get(root, "item_id"));
                }

                /* the ordering contract: nothing may follow response.completed
                 * (the guest breaks its read loop on it) */
                if (seen_completed) {
                    note("turn %ld: event '%s' after response.completed — the "
                         "guest breaks its read loop on completed; this tail "
                         "is never parsed", turn, event);
                }

                int is_added_fc = fc_item_ev &&
                    strcmp(event, "response.output_item.added") == 0;
                int is_done_fc = fc_item_ev &&
                    strcmp(event, "response.output_item.done") == 0;
                int is_args_ev =
                    strcmp(event, "response.function_call_arguments.delta") == 0 ||
                    strcmp(event, "response.function_call_arguments.done") == 0;

                if (is_added_fc) {
                    struct open_item *o = open_item_find_iid(open_head, fc_iid);
                    if (o) {
                        /* replay/dup of a still-open item: reset its buffer and
                         * re-capture identity (idempotent for a replayed id) */
                        o->ev.len = 0;
                        o->args.len = 0; /* P5: the arg accumulator restarts */
                        free(o->call_id);
                        o->call_id = fc_cid ? xstrdup(fc_cid) : NULL;
                        free(o->name);
                        o->name = fc_nm ? xstrdup(fc_nm) : NULL;
                        note("turn %ld: replayed added for item_id=%s — buffer "
                             "reset", turn, fc_iid ? fc_iid : "(none)");
                    } else {
                        if (open_head) {
                            note("turn %ld: INTERLEAVED function_call items "
                                 "(added for %s while %s is open) — per-item "
                                 "buffers engaged; the single-accumulator merge "
                                 "that caused the silent allow cannot happen",
                                 turn, fc_iid ? fc_iid : "(none)",
                                 open_head->item_id ? open_head->item_id
                                                    : "(none)");
                        }
                        o = open_item_new(fc_iid, fc_cid, fc_nm);
                        open_item_push(&open_head, &open_tail, o);
                    }
                    tb_put(&o->ev, (const char *)buf + ev_start, i - ev_start);
                } else if (is_args_ev) {
                    struct open_item *o = open_item_find_iid(open_head,
                                                             args_item_id);
                    if (o) {
                        /* P5: mirror the GUEST's argument accumulator exactly
                         * (openai_responses.c:171-194): deltas append in
                         * arrival order, and the .done event's full
                         * `arguments` is used ONLY when no delta arrived.  The
                         * justification is judged on these bytes. */
                        int is_delta = strcmp(
                            event,
                            "response.function_call_arguments.delta") == 0;
                        yyjson_val *pv = yyjson_obj_get(
                            root, is_delta ? "delta" : "arguments");
                        const char *txt = pv ? yyjson_get_str(pv) : NULL;
                        if (txt && (is_delta || o->args.len == 0)) {
                            if (o->args.len + strlen(txt) > FH_FRAME_MAX) {
                                /* the accumulator outgrew the frame cap: the
                                 * host can no longer judge what the guest will
                                 * dispatch, so while armed it must not serve
                                 * the stream (fail-closed, as for an oversize
                                 * event) */
                                note("turn %ld: the argument accumulator "
                                     "exceeds the frame cap; %s",
                                     turn,
                                     policy_armed()
                                         ? "REFUSING the stream (armed: an "
                                           "unjudgeable call must not cross)"
                                         : "kept raw (unarmed)");
                                if (policy_armed()) exit(1);
                            } else {
                                tb_put(&o->args, txt, strlen(txt));
                            }
                        }
                        tb_put(&o->ev, (const char *)buf + ev_start,
                               i - ev_start);
                    } else {
                        /* a delta with no open accumulator: forward raw (the
                         * guest ignores deltas it cannot attach) */
                        tb_put(&out, (const char *)buf + ev_start,
                               i - ev_start);
                    }
                } else if (is_done_fc) {
                    struct open_item *o = open_item_find_iid(open_head, fc_iid);
                    if (!o) o = open_item_find_cid(open_head, fc_cid);
                    if (o) {
                        tb_put(&o->ev, (const char *)buf + ev_start,
                               i - ev_start);
                        /* judge THIS item with ITS OWN identity, on the
                         * arguments the GUEST will dispatch: the accumulator
                         * it emits at this event (see the jargs note below) */
                        const char *nm = o->name ? o->name : fc_nm;
                        const char *cid = o->call_id ? o->call_id : fc_cid;
#ifdef FH_MUTANT_JUDGE_DONE_ARGS
                        /* P5 PRE-FIX CONTROL (build/fx-hostgate-doneargs):
                         * the judge reads the DONE EVENT's own `arguments`
                         * field instead of the accumulator the guest will
                         * dispatch.  A real provider sends arguments:"" in
                         * added and every byte in the DELTAS, so this build
                         * denies honest, fully justified calls — the "agent
                         * effectively dead while the log looks protective"
                         * shape, caught by the delta-mirror arm's marker. */
                        const char *jargs = fc_args;
#else
                        /* THE JUDGMENT SOURCE IS THE GUEST'S SOURCE: the guest
                         * dispatches the ACCUMULATOR as-is (openai_responses.c:
                         * 171-194 emits it, possibly empty, at this event); its
                         * ONLY fallback is the function_call_arguments.done
                         * EVENT's `arguments`, already mirrored at is_args_ev
                         * above.  It never reads the done ITEM's own field, so a
                         * fallback to fc_args here would judge a call on bytes
                         * the guest drops: a stream that puts the justification
                         * ONLY in the done item's field would look justified
                         * here and dispatch with none.  Judged on the
                         * accumulator (possibly empty) -> absent-justification,
                         * exactly what the guest dispatches. */
                        const char *jargs = o->args.p;
#endif
                        if (!cid || !*cid) {
                            note("turn %ld: function_call item WITHOUT a "
                                 "call_id — not recorded, not joinable", turn);
                            tb_put(&out, o->ev.p, o->ev.len);
                        } else {
                            const char *author = NULL, *refusal = NULL;
                            char reason[1024];
                            int deny = nm && policy_armed() &&
                                       call_judge(nm, jargs, &author, &refusal,
                                                  reason, sizeof reason);
                            if (deny) {
                                char *denial = xmalloc(strlen(reason) + 64);
                                snprintf(denial, strlen(reason) + 64,
                                         "(denied by host policy: %s)", reason);
                                dmap_put(cid, nm, reason, denial, turn);
                                row_call_append(cid, nm, jargs, turn,
                                                VERDICT_DENIED, author, refusal,
                                                reason, denial);
                                note("turn %ld: DENIED call_id=%s true_name=%s "
                                     "author=%s refusal=%s -> serving the "
                                     "reserved name",
                                     turn, cid, nm, author, refusal);
#ifdef FH_MUTANT_NO_REWRITE
                                tb_put(&out, o->ev.p, o->ev.len);
#else
                                item_emit_rewritten(&out,
                                                    (const unsigned char *)o->ev.p,
                                                    o->ev.len, turn);
#endif
                                free(denial);
                            } else {
                                row_call_append(cid, nm, jargs, turn,
                                                policy_armed() ? VERDICT_ALLOWED
                                                               : VERDICT_NONE,
                                                policy_armed() ? authors_ran()
                                                               : NULL,
                                                NULL, NULL, NULL);
                                tb_put(&out, o->ev.p, o->ev.len); /* verbatim */
                            }
                        }
                        open_item_remove(&open_head, &open_tail, o);
                        open_item_free(o);
                    } else {
                        /* a done with NO matching open item (never-opened, or a
                         * duplicate done after the first removed it).  It still
                         * carries name + call_id + arguments, so it is judgeable
                         * ON THE SPOT; the true name must not cross while armed.
                         * Its args are the item's own field (no delta ever
                         * arrived for it).  P45-fix: a refusal here IS recorded
                         * as a row (the instrument must count what the host
                         * refused) but still makes NO deny-map entry — nothing
                         * was judged as a call the guest will dispatch, so no
                         * substitution leg exists. */
#ifndef FH_MUTANT_NO_REWRITE
                        const char *author = NULL, *refusal = NULL;
                        char reason[1024];
                        if (fc_nm && policy_armed() &&
                            call_judge(fc_nm, fc_args, &author, &refusal,
                                       reason, sizeof reason)) {
                            char *json = event_json_set_item_name(data, data_len,
                                                                  FH_RESERVED_NAME);
                            if (!json) {
                                /* FAIL-CLOSED: an unjudgeable denied done must
                                 * not forward the true name */
                                note("turn %ld: FATAL: cannot rewrite an "
                                     "unopened denied item's done event; "
                                     "refusing to forward the true name", turn);
                                exit(1);
                            }
                            tb_puts(&out, "event: response.output_item.done\n");
                            tb_puts(&out, "data: ");
                            tb_puts(&out, json);
                            tb_puts(&out, "\n\n");
                            free(json);
                            /* P45-fix (review item b): RECORD the refusal.  It
                             * was not recorded from P3 on, which left the
                             * denial-rate instrument and the exit aggregate
                             * blind to this shape: a turn whose only refusals
                             * are unopened denials reported calls=0 and
                             * denial_rate=null — an instrument reading its own
                             * blind spot as "nothing happened".
                             * ONE row per call_id: a duplicate done for an item
                             * the first done already judged must not be counted
                             * twice (the join answers the oldest pending row,
                             * so a second row on the same key would never
                             * resolve and would report a false UNRESOLVED at
                             * exit).  NO deny-map entry (unchanged from P3):
                             * nothing was dispatched and no
                             * function_call_output can follow an item whose
                             * added never arrived, so there is no substitution
                             * leg to arm — and arming one would emit a false
                             * unresolved-substitution anomaly.  The row is
                             * pending, by definition (nothing answered it),
                             * and the exit report names it unresolved. */
                            int known = 0;
                            for (size_t ri = 0; ri < g_nrows; ri++) {
                                if (g_rows[ri].kind == ROW_CALL && fc_cid &&
                                    strcmp(g_rows[ri].call_id, fc_cid) == 0) {
                                    known = 1;
                                    break;
                                }
                            }
                            if (known) {
                                note("turn %ld: unopened denied done for "
                                     "call_id=%s is ALREADY recorded — not "
                                     "counted a second time", turn, fc_cid);
                            } else if (fc_cid && *fc_cid) {
                                char *denial = xmalloc(strlen(reason) + 64);
                                snprintf(denial, strlen(reason) + 64,
                                         "(denied by host policy: %s)", reason);
                                row_call_append(fc_cid, fc_nm, fc_args, turn,
                                                VERDICT_DENIED, author, refusal,
                                                reason, denial);
                                free(denial);
                            } else {
                                note("turn %ld: unopened denied done WITHOUT a "
                                     "call_id — refused, but the join key is "
                                     "missing, so it cannot be counted", turn);
                            }
                            note("turn %ld: done for an item with NO open "
                                 "buffer carries a DENIED name — rewritten, "
                                 "and the refusal is recorded (never judged: "
                                 "nothing was dispatched)", turn);
                        } else
#endif
                        {
                            note("turn %ld: done for an item with NO open "
                                 "buffer (name-only-at-done) — forwarded "
                                 "verbatim, unjudged", turn);
                            tb_put(&out, (const char *)buf + ev_start,
                                   i - ev_start);
                        }
                    }
                } else if (strcmp(event, "response.completed") == 0 &&
                           yyjson_is_obj(root)) {
                    seen_completed = 1;
#ifdef FH_MUTANT_NO_REWRITE
                    tb_put(&out, (const char *)buf + ev_start, i - ev_start);
#else
                    /* the completed event's output array is not read by
                     * today's guest — rewrite it anyway so the byte-level
                     * invariant holds against a guest that reads raw */
                    /* P3-fix: an item still OPEN when completed arrives was
                     * never judged (its done never came), so its call_id is
                     * not in the deny map and its true name would cross in
                     * completed's output array.  Seed the map from the open
                     * items' own captured names so the rewrite below picks
                     * them up.  NO verdict row: nothing was judged here.
                     * The seeded denial text must NOT be empty: if this
                     * call_id ever reappears as a function_call_output, the
                     * outbound substitution writes the denial text over the
                     * guest's output, and an empty one would put a BLANK tool
                     * result in front of the model (a silent degradation).  No
                     * author refused this call, so the text says exactly that:
                     * the item never completed and was never judged. */
                    for (struct open_item *oi = open_head; oi; oi = oi->next) {
                        if (oi->call_id && oi->name && policy_armed() &&
                            policy_denied(oi->name)) {
                            dmap_put(oi->call_id, oi->name,
                                     FH_REASON_UNJUDGED_ITEM,
                                     "(denied by host policy: "
                                     FH_REASON_UNJUDGED_ITEM ")",
                                     turn);
                            note("turn %ld: item %s was STILL OPEN when "
                                 "completed arrived — its name in completed's "
                                 "output array rewritten (unjudged)", turn,
                                 oi->item_id ? oi->item_id : "(no id)");
                        }
                    }
                    char *json = event_json_rewrite_completed(data, data_len);
                    if (json) {
                        tb_puts(&out, "event: response.completed\n");
                        tb_puts(&out, "data: ");
                        tb_puts(&out, json);
                        tb_puts(&out, "\n\n");
                        free(json);
                    } else {
                        tb_put(&out, (const char *)buf + ev_start,
                               i - ev_start);
                    }
#endif
                } else {
                    /* every other event (reasoning deltas, created,
                     * in_progress, reasoning items, ...) forwards verbatim and
                     * immediately — text and reasoning deltas still stream */
                    tb_put(&out, (const char *)buf + ev_start, i - ev_start);
                }
                if (doc) yyjson_doc_free(doc);
            } else {
                /* not a parseable event (no event+data pair, or over-cap):
                 * forward the raw span — the stream stays byte-identical */
                tb_put(&out, (const char *)buf + ev_start, i - ev_start);
            }
            event[0] = '\0';
            have_event = 0;
            have_data = 0;
            data_len = 0;
            ev_start = i;
            continue;
        }

        const char *line = (const char *)buf + start;
        if (ll > 6 && memcmp(line, "event:", 6) == 0) {
            size_t v = 6;
            while (v < ll && (line[v] == ' ' || line[v] == '\t')) v++;
            size_t take = ll - v;
            if (take >= sizeof event) take = sizeof event - 1;
            memcpy(event, line + v, take);
            event[take] = '\0';
            have_event = 1;
        } else if (ll > 5 && memcmp(line, "data:", 5) == 0) {
            size_t v = 5;
            while (v < ll && (line[v] == ' ' || line[v] == '\t')) v++;
            size_t take = ll - v;
            if (data_len + take + 2 > FH_FRAME_MAX) {
                note("turn %ld: SSE data exceeds the frame cap; %s", turn,
                     policy_armed() ? "REFUSING the stream (armed: an unjudgeable event must not cross)" : "event kept raw (unarmed)");
                if (policy_armed()) exit(1);
                data_len = 0;
                have_data = 0;
            } else {
                if (data_len + take + 2 > data_cap) {
                    data_cap = (data_len + take + 2) * 2;
                    data = realloc(data, data_cap);
                    if (!data) die_errno("realloc sse data");
                }
                if (have_data) data[data_len++] = '\n';
                memcpy(data + data_len, line + v, take);
                data_len += take;
                have_data = 1;
            }
        }
    }

    /* any item still open at stream end: NOTHING was judged, so there is no
     * verdict to enforce — forward the held bytes verbatim and say so (loud;
     * the alternative, dropping them, would be suppression).  In insertion
     * order. */
    while (open_head) {
        struct open_item *o = open_head;
        open_head = o->next;
        if (o->ev.len) {
            note("turn %ld: function_call item %s did NOT complete before the "
                 "stream ended — held events forwarded verbatim, unjudged",
                 turn, o->item_id ? o->item_id : "(no id)");
            tb_put(&out, o->ev.p, o->ev.len);
        }
        open_item_free(o);
    }
    /* the unterminated tail: raw, byte-identical (the guest's parser never
     * dispatches an event without its blank line) */
    if (ev_start < len) tb_put(&out, (const char *)buf + ev_start, len - ev_start);
    free(data);
    *out_len = out.len;
    return (unsigned char *)out.p;
#endif /* FH_MUTANT_SINGLE_ITEM */
}

/* ── the join leg: read function_call_outputs out of a request frame (P2) ─── */

static void join_pass(const unsigned char *body, size_t body_len, long turn) {
    if (!body || body_len == 0) {
        note("turn %ld: request frame body is empty; no join pass", turn);
        return;
    }
    yyjson_doc *doc = yyjson_read((const char *)body, body_len, 0);
    if (!doc) {
        note("turn %ld: request frame body is not JSON (%zu bytes); no join "
             "pass",
             turn, body_len);
        return;
    }
    yyjson_val *root = yyjson_doc_get_root(doc);
    yyjson_val *input =
        yyjson_is_obj(root) ? yyjson_obj_get(root, "input") : NULL;
    if (!yyjson_is_arr(input)) {
        note("turn %ld: request frame carries no input array; no join pass",
             turn);
        yyjson_doc_free(doc);
        return;
    }
    yyjson_val *it;
    size_t idx, max;
    yyjson_arr_foreach(input, idx, max, it) {
        if (!yyjson_is_obj(it)) continue;
        const char *ty = yyjson_get_str(yyjson_obj_get(it, "type"));
        if (!ty || strcmp(ty, "function_call_output") != 0) continue;
        const char *cid = yyjson_get_str(yyjson_obj_get(it, "call_id"));
        const char *out = yyjson_get_str(yyjson_obj_get(it, "output"));
        if (!cid || !*cid) {
            note("turn %ld: function_call_output WITHOUT a call_id — not "
                 "joinable",
                 turn);
            continue;
        }
#ifdef FH_MUTANT_NO_JOIN
        /* P2 MUTATION BLIND (the gate builds this file as
         * build/fx-hostgate-mutant): the resolution pass is compiled OUT.
         * The frame is still parsed — only the join is missing — so the
         * mutant's failure is a WRONG RECORD (every row stays pending while
         * the fireable output crossed on the wire), not a crash: exactly the
         * silent-degradation direction the gate must catch by content. */
        (void)out;
#else
        row_resolve(cid, out, turn);
#endif
    }
    yyjson_doc_free(doc);
}

/* ── the outbound leg (P3): substitute the truth, then record what the
 * model would see.  THE DENIAL MUST REACH THE MODEL AS THE CALL'S OWN
 * RESULT — the guest can only synthesize a sentinel because it cannot know
 * why; the host owns this leg.  For each item of the request's input array,
 * KEYED ON call_id and UNCONDITIONAL on deny-map membership (never a
 * content match):
 *   function_call          -> name RESTORED to the true name (the guest
 *                             serialized the reserved name; without the
 *                             restore the model would see a call it never
 *                             made);
 *   function_call_output   -> output REPLACED with the denial text.
 * In the OFFLINE arm the upstream is canned, so the rewritten frame's only
 * observable is --dump-requests (one compact JSON line per turn, appended);
 * P10's live lane sends this same frame up the wire.  Telemetry (never a
 * stop): an output matching NO decoded call -> unjoined-output row; an
 * output for a denied call that is NOT one of the two known sentinels ->
 * echo-anomaly row. */
static int known_sentinel(const char *s) {
    return s && (strcmp(s, "(tool disabled)") == 0 ||
                 strcmp(s, "(tool call failed)") == 0);
}

/* Returns the REWRITTEN model-facing frame (a malloc'd, NUL-terminated JSON
 * document — the exact buffer P10's live lane sends up the wire), or NULL
 * when there is no input array (nothing to substitute, nothing to record).
 * The CALLER records the returned frame (--dump-requests appends it), so the
 * dump is not self-authored: it is the object the proxy would actually send. */
static char *outbound_pass(const unsigned char *body, size_t body_len,
                           long turn) {
    if (!body || body_len == 0) return NULL;
    yyjson_doc *doc = yyjson_read((const char *)body, body_len, 0);
    if (!doc) {
        note("turn %ld: request frame body is not JSON (%zu bytes); no "
             "outbound pass",
             turn, body_len);
        return NULL;
    }
    yyjson_val *root = yyjson_doc_get_root(doc);
    yyjson_val *input =
        yyjson_is_obj(root) ? yyjson_obj_get(root, "input") : NULL;
    if (!yyjson_is_arr(input)) {
        yyjson_doc_free(doc);
        return NULL; /* nothing to substitute, nothing to dump */
    }

    struct tbuf arr = {0};
    tb_puts(&arr, "[");
    yyjson_val *it;
    size_t idx, max;
    yyjson_arr_foreach(input, idx, max, it) {
        if (idx > 0) tb_puts(&arr, ",");
        const char *ty = yyjson_is_obj(it)
            ? yyjson_get_str(yyjson_obj_get(it, "type")) : NULL;
        const char *cid = yyjson_is_obj(it)
            ? yyjson_get_str(yyjson_obj_get(it, "call_id")) : NULL;
        struct deny_key *k = cid ? dmap_find(cid) : NULL;

        if (ty && strcmp(ty, "function_call") == 0 && k) {
#if !defined(FH_MUTANT_NO_REWRITE) && !defined(FH_MUTANT_NO_SUBSTITUTE)
            tb_put_obj_strset(&arr, it, "name", k->true_name);
            note("turn %ld: outbound RESTORED call_id=%s name=%s (the guest "
                 "serialized the reserved name)",
                 turn, cid, k->true_name);
#else
            tb_put_val(&arr, it); /* the control pins the un-substituted leg */
#endif
        } else if (ty && strcmp(ty, "function_call_output") == 0) {
            const char *out = yyjson_get_str(yyjson_obj_get(it, "output"));
            if (k) {
                /* telemetry: a denied call's output that is NOT one of the
                 * two known sentinels is an echo-anomaly (the record keeps
                 * the evidence; substitution is unconditional regardless) */
                if (!known_sentinel(out)) {
                    row_anom_append(ROW_ANOM_ECHO, cid,
                                    out ? out : "", turn);
                    note("turn %ld: echo-anomaly: call_id=%s is denied but "
                         "the guest's output is not a known sentinel",
                         turn, cid);
                }
#if !defined(FH_MUTANT_NO_REWRITE) && !defined(FH_MUTANT_NO_SUBSTITUTE)
                tb_put_obj_strset(&arr, it, "output", k->denial_text);
                /* the substitution happened: the denial reached the model as
                 * the call's own result — close this denial's window */
                k->subst_pending = 0;
                note("turn %ld: outbound SUBSTITUTED call_id=%s output -> the "
                     "denial text",
                     turn, cid);
#else
                tb_put_val(&arr, it);
#endif
            } else {
                /* telemetry: an output matching NO call the host ever
                 * decoded (denied or accepted) — the guest put words in the
                 * conversation for a call the model never made */
                int known = 0;
                for (size_t r = 0; r < g_nrows; r++) {
                    if (g_rows[r].kind == ROW_CALL &&
                        strcmp(g_rows[r].call_id, cid ? cid : "") == 0) {
                        known = 1;
                        break;
                    }
                }
                if (!known && cid && *cid) {
                    row_anom_append(ROW_ANOM_UNJOINED, cid,
                                    out ? out : "", turn);
                    note("turn %ld: unjoined-output: call_id=%s matches NO "
                         "decoded call",
                         turn, cid);
                }
                tb_put_val(&arr, it);
            }
        } else {
            tb_put_val(&arr, it);
        }
    }
    tb_puts(&arr, "]");

    /* Rebuild the frame: every non-input member verbatim — EXCEPT `tools` when
     * the justification is required, because then the HOST owns the tools
     * catalog (P5): a member the guest never sends (MEASURED, agent_loop.c:68)
     * and the one the model must be told what the schema requires. */
    struct tbuf frame = {0};
    tb_puts(&frame, "{");
    int first = 1;
    yyjson_val *k2, *v2;
    size_t ridx, rmax;
    yyjson_obj_foreach((yyjson_val *)root, ridx, rmax, k2, v2) {
        const char *kn = yyjson_get_str(k2);
        if (g_require_justify && kn && strcmp(kn, "tools") == 0) {
            note("turn %ld: the request carried a `tools` member; REPLACED by "
                 "the host's pinned catalog (the host owns the wire, and a "
                 "leftover catalog would be a second, unpinned one)",
                 turn);
            continue;
        }
        if (!first) tb_puts(&frame, ",");
        first = 0;
        char *jk = json_str(kn ? kn : "");
        tb_puts(&frame, jk);
        free(jk);
        tb_puts(&frame, ":");
        if (kn && strcmp(kn, "input") == 0) tb_put(&frame, arr.p, arr.len);
        else tb_put_val(&frame, v2);
    }
#ifdef FH_MUTANT_NO_TOOLS_INJECT
    /* P5 MUTATION BLIND (build/fx-hostgate-notools): the injection is compiled
     * out while --require-justification still DENIES an unjustified call.  The
     * model is never told what is required, so the lane dies unjustified with
     * a perfectly protective-looking record — the dead-agent shape the
     * denial-rate instrument exists to make visible. */
    if (g_require_justify)
        note("turn %ld: tools-array injection COMPILED OUT "
             "(FH_MUTANT_NO_TOOLS_INJECT) — the model is NOT told that a "
             "justification is required", turn);
#else
    if (g_require_justify) {
        if (!first) tb_puts(&frame, ",");
        first = 0;
        tb_puts(&frame, "\"tools\":");
        tools_inject_json(&frame);
    }
#endif
    tb_puts(&frame, "}");
    free(arr.p);
    yyjson_doc_free(doc);
    return frame.p; /* ownership to the caller (the live-lane send buffer) */
}

/* ── the pending-substitution instrument (P3-fix, SHOULD-FIX 3) ────────────
 *
 * Every denied call_id MUST be resolved by the NEXT request: the outbound
 * pass substitutes the denial text into the function_call_output the guest
 * replays, and only that substitution clears subst_pending.  A denied
 * call_id whose substitution window CLOSED — a subsequent request frame was
 * fully processed without substituting it — is a missed outbound leg: the
 * model saw a call it never made and never learned why, and nothing else in
 * the record would say so.  This check runs once per turn, AFTER the
 * outbound pass and BEFORE the decode (which re-denies the canned stream),
 * and emits an `unresolved-substitution` anomaly row for each such call_id.
 * (A denial on the LAST turn, whose next request never arrives, is the
 * broader unresolved-JOIN case already reported by log_exit_report — this
 * instrument is specifically the join-fired-but-not-substituted direction.) */
static void subst_unresolved_check(long turn) {
    for (size_t i = 0; i < g_ndmap; i++) {
        struct deny_key *k = &g_dmap[i];
        if (k->subst_pending && k->denied_turn < turn) {
            row_anom_append(ROW_ANOM_UNRESOLVED_SUBST, k->call_id,
                            k->true_name ? k->true_name : "", turn);
            note("turn %ld: unresolved-substitution: call_id=%s (denied on "
                 "turn %ld) never received its outbound substitution",
                 turn, k->call_id, k->denied_turn);
            /* report once per missed window; the next decode's re-denial opens
             * a fresh window with a fresh denied_turn */
            k->subst_pending = 0;
        }
    }
}

/* ── the request frame reader ───────────────────────────────────────────── */

#define FH_CARRY_CAP 4096
#define FH_DIGITS_CAP 24 /* %llu is at most 20 digits; refuse longer */

struct frame_reader {
    /* bytes read past a completed frame (a pipelining guest) are carried to
     * the next call, never dropped */
    unsigned char carry[FH_CARRY_CAP];
    size_t carry_len;
    /* header accumulation: decimal digits up to '\n' */
    char digits[FH_DIGITS_CAP];
    size_t digits_len;
    int have_len; /* the '\n' was seen: body_left is live */
    unsigned long long body_left;
    unsigned long long frame_bytes;
    unsigned long long last_frame_bytes; /* header + body of the last frame */
    /* P2: the body is CAPTURED, not discarded — the join pass reads the
     * function_call_outputs out of it.  Grown to fit; capped at
     * FH_FRAME_MAX (an absurd frame is a protocol violation). */
    unsigned char *body;
    size_t body_cap, body_len, last_frame_body_len;
};

static void frame_reader_init(struct frame_reader *fr) {
    memset(fr, 0, sizeof *fr);
}

/* Feed one byte span into the state machine.  Returns 1 when a frame
 * completed (*consumed says how many bytes of src it took), 0 when more
 * bytes are needed, -1 on a protocol violation. */
static int frame_feed(struct frame_reader *fr, const unsigned char *src,
                      size_t n, size_t *consumed) {
    size_t i = 0;
    while (i < n) {
        if (!fr->have_len) {
            if (src[i] == '\n') {
                char digits[FH_DIGITS_CAP + 1];
                char *end = NULL;
                if (fr->digits_len == 0) return -1; /* empty count */
                memcpy(digits, fr->digits, fr->digits_len);
                digits[fr->digits_len] = '\0';
                fr->body_left = strtoull(digits, &end, 10);
                if (!end || *end != '\0') return -1; /* not decimal */
                fr->have_len = 1;
                fr->frame_bytes = fr->digits_len + 1;
                i++;
                continue;
            }
            if (fr->digits_len >= FH_DIGITS_CAP) return -1;
            fr->digits[fr->digits_len++] = (char)src[i++];
            continue;
        }
        /* body: capture the content (P2's join pass reads the
         * function_call_outputs out of it) */
        {
            size_t take = n - i;
            if ((unsigned long long)take > fr->body_left) {
                take = (size_t)fr->body_left;
            }
            if (fr->body_len + take + 1 > FH_FRAME_MAX) return -1;
            if (fr->body_len + take + 1 > fr->body_cap) {
                size_t nc = fr->body_cap ? fr->body_cap : 1024;
                while (nc < fr->body_len + take + 1) nc *= 2;
                unsigned char *nb = realloc(fr->body, nc);
                if (!nb) return -1;
                fr->body = nb;
                fr->body_cap = nc;
            }
            memcpy(fr->body + fr->body_len, src + i, take);
            fr->body_len += take;
            fr->body_left -= take;
            fr->frame_bytes += take;
            i += take;
        }
        if (fr->body_left == 0) {
            fr->last_frame_bytes = fr->frame_bytes;
            if (fr->body) fr->body[fr->body_len] = '\0'; /* JSON needs no scan for an end */
            fr->last_frame_body_len = fr->body_len;
            /* reset for the next frame; the captured body stays readable */
            fr->digits_len = 0;
            fr->have_len = 0;
            fr->body_len = 0;
            *consumed = i;
            return 1;
        }
    }
    *consumed = i;
    return 0;
}

/* Read one request frame from the master.  Returns 0 when a frame is
 * complete, 1 on a turn boundary (EIO / EOF: the guest closed the device
 * between turns), -1 on a hard error or protocol violation. */
static int read_frame(int fd, struct frame_reader *fr) {
    for (;;) {
        if (fr->carry_len > 0) {
            size_t consumed = 0;
            int r = frame_feed(fr, fr->carry, fr->carry_len, &consumed);
            if (r < 0) return -1;
            memmove(fr->carry, fr->carry + consumed, fr->carry_len - consumed);
            fr->carry_len -= consumed;
            if (r == 1) return 0;
        }

        unsigned char chunk[4096];
        ssize_t n = read(fd, chunk, sizeof chunk);
        if (n < 0) {
            if (errno == EINTR) continue;
            if (errno == EIO) return 1; /* last slave closed: turn boundary */
            return -1;
        }
        if (n == 0) return 1; /* EOF: same boundary meaning */

        size_t consumed = 0;
        int r = frame_feed(fr, chunk, (size_t)n, &consumed);
        if (r < 0) return -1;
        if (r == 1) {
            /* keep bytes past the frame for the next call */
            size_t rest = (size_t)n - consumed;
            if (rest > FH_CARRY_CAP) return -1; /* would drop bytes: refuse */
            memcpy(fr->carry, chunk + consumed, rest);
            fr->carry_len = rest;
            return 0;
        }
    }
}

/* ── main ────────────────────────────────────────────────────────────────── */

static void usage(void) {
    note("usage: %s --upstream FILE --slave-file PATHFILE --log LOGFILE [--turns N] [--deny NAME]... [--require-justification] [--dump-requests PATH]",
         prog);
    note("  --upstream      the canned SSE stream served each turn");
    note("  --slave-file    where the pty slave path is published (one line)");
    note("  --log           THE ONE LOG: append-only JSONL, one row per call");
    note("                  (required — a proxy that records nothing is not");
    note("                  this seat, it is a silent hole in the record)");
    note("  --turns N       exit after serving N request frames (default: never)");
    note("  --deny NAME     the pinned placeholder denylist (repeatable).  With");
    note("                  none given and no --require-justification NO policy");
    note("                  ran: nothing is rewritten and no verdict field is");
    note("                  rendered (the P2 shape)");
    note("  --require-justification  arm P5: inject the pinned `tools` catalog");
    note("                  (justification REQUIRED in each schema) into the");
    note("                  forwarded request, and deny by name any call whose");
    note("                  justification is absent or malformed");
    note("  --dump-requests PATH  append the REWRITTEN model-facing request");
    note("                  frame (one compact JSON line per turn) — the only");
    note("                  observable of the outbound substitution offline");
    note("  --print-catalog / --print-catalog-sha  print the pinned verb");
    note("                  catalog (one name per line) / its sha256, for the");
    note("                  gate's INDEPENDENT cross-check against the real");
    note("                  VERBS[] table, and exit");
}

int main(int argc, char **argv) {
    const char *upstream_path = NULL;
    const char *slave_file = NULL;
    long max_turns = -1; /* -1: serve forever */

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--upstream") && i + 1 < argc) {
            upstream_path = argv[++i];
        } else if (!strcmp(argv[i], "--slave-file") && i + 1 < argc) {
            slave_file = argv[++i];
        } else if (!strcmp(argv[i], "--log") && i + 1 < argc) {
            g_log_path = argv[++i];
        } else if (!strcmp(argv[i], "--turns") && i + 1 < argc) {
            char *end = NULL;
            max_turns = strtol(argv[++i], &end, 10);
            if (!end || *end != '\0' || max_turns < 1) {
                note("FATAL: --turns needs a positive integer");
                usage();
                return 2;
            }
        } else if (!strcmp(argv[i], "--deny") && i + 1 < argc) {
            const char *name = argv[++i];
            const char **nl = realloc((void *)g_deny_list,
                                      (g_ndeny + 1) * sizeof *g_deny_list);
            if (!nl) die_errno("realloc denylist");
            g_deny_list = nl;
            g_deny_list[g_ndeny++] = name;
        } else if (!strcmp(argv[i], "--require-justification")) {
            g_require_justify = 1;
        } else if (!strcmp(argv[i], "--dump-requests") && i + 1 < argc) {
            g_dump_path = argv[++i];
        } else if (!strcmp(argv[i], "--print-catalog")) {
            /* The gate's INDEPENDENT cross-check of the pinned catalog against
             * the real VERBS[] table: one name per line on stdout, then exit —
             * BEFORE any check or any pty, because this is a query about the
             * binary, not a run. */
            size_t n = fh_catalog_count();
            char nm[128];
            for (size_t k = 0; k < n; k++) {
                if (fh_catalog_nth(k, nm, sizeof nm)) printf("%s\n", nm);
            }
            return 0;
        } else if (!strcmp(argv[i], "--print-catalog-sha")) {
            char got[65];
            sha256_hex(fh_verb_catalog, strlen(fh_verb_catalog), got);
            printf("%s\n", got);
            return 0;
        } else {
            note("FATAL: unknown/incomplete argument '%s'", argv[i]);
            usage();
            return 2;
        }
    }
    if (!upstream_path || !slave_file || !g_log_path) {
        usage();
        return 2;
    }

    /* P4 — THE RESERVED-NAME CONTRACT, checked FIRST: a refusal has to happen
     * before the slave path is published or any byte is served, because
     * "the proxy started and the reserved name was callable" is a silent allow
     * with no later moment at which it could be made loud. */
    fh_catalog_check();

    /* the upstream canned stream, read whole once — every turn replays it
     * from the start (the offline arm's provider is deterministic) */
    FILE *up = fopen(upstream_path, "rb");
    if (!up) die_errno("cannot open upstream");
    if (fseek(up, 0, SEEK_END) != 0) die_errno("fseek upstream");
    long ul = ftell(up);
    if (ul <= 0) {
        note("FATAL: upstream %s is empty/unmeasurable (%ld bytes)", upstream_path, ul);
        return 1;
    }
    rewind(up);
    size_t upstream_len = (size_t)ul;
    unsigned char *upstream = malloc(upstream_len);
    if (!upstream) die_errno("malloc upstream");
    if (fread(upstream, 1, upstream_len, up) != upstream_len) die_errno("fread upstream");
    fclose(up);

    /* the PTY pair: master here, slave path handed to the guest */
    int master = posix_openpt(O_RDWR | O_NOCTTY);
    if (master < 0) die_errno("posix_openpt");
    if (grantpt(master) != 0) die_errno("grantpt");
    if (unlockpt(master) != 0) die_errno("unlockpt");
    char slave_path[128];
    const char *sp = ptsname(master);
    if (!sp) die_errno("ptsname");
    snprintf(slave_path, sizeof slave_path, "%s", sp);

    /* RAW line discipline, set through the master fd (the pty's termios is
     * shared with the slave the guest will open).  Without this the line
     * discipline echoes the guest's request into its own read stream and
     * ONLCR-rewrites the SSE's newlines — measured phantom. */
    struct termios t;
    if (tcgetattr(master, &t) != 0) die_errno("tcgetattr");
    cfmakeraw(&t);
    if (tcsetattr(master, TCSANOW, &t) != 0) die_errno("tcsetattr");

    /* a tty write reports EIO, not SIGPIPE — but never bet the gate on it */
    signal(SIGPIPE, SIG_IGN);

    FILE *pub = fopen(slave_file, "w");
    if (!pub) die_errno("cannot write --slave-file");
    fprintf(pub, "%s\n", slave_path);
    fclose(pub);

    note("slave: %s", slave_path);
    note("upstream: %s (%zu bytes); turns: %s",
         upstream_path, upstream_len,
         max_turns < 0 ? "unlimited" : "bounded");
    note("log: %s (one JSONL row per call)", g_log_path);
    /* The honesty lines: name what is ACTUALLY armed.  The denylist is a
     * placeholder author (never P6/P7, which do not exist); the justification
     * check is real; the reserved name is refused by the verbs server even in
     * an allow-all lane (structural backstop, P3) AND checked against the
     * pinned catalog at startup (P4). */
    if (policy_armed()) {
        note("policy: authors armed = %s; reserved name=%s (P4 contract checked "
             "at startup)",
             authors_ran(), FH_RESERVED_NAME);
        for (size_t d = 0; d < g_ndeny; d++) {
            note("policy: PLACEHOLDER denylist entry \"%s\"", g_deny_list[d]);
        }
        if (g_require_justify) {
            note("policy: JUSTIFICATION REQUIRED for every call (P5) — the tool "
                 "catalog is injected into the forwarded request and an "
                 "absent/malformed justification is DENIED BY NAME "
                 "(absent-justification / malformed-justification)");
        }
    } else {
        note("policy: NONE — no denylist given and no --require-justification, "
             "so no verdict fields are rendered; every call is recorded and "
             "forwarded verbatim");
    }
    if (g_dump_path) {
        note("dump-requests: %s (the REWRITTEN model-facing frame, one line "
             "per turn)",
             g_dump_path);
    }

    struct frame_reader fr;
    frame_reader_init(&fr);
    long served = 0;
    int in_boundary = 0; /* log a boundary EPISODE once, not every retry */

    for (;;) {
        int r = read_frame(master, &fr);
        if (r < 0) {
            note("FATAL: request frame protocol violation");
            return 1;
        }
        if (r == 1) {
            /* turn boundary: the guest closed the device between turns.
             * Normal (mechanic (b) in the header); back off so the EIO
             * retry cannot spin until the next slave open. */
            if (!in_boundary) {
                struct timespec ts = { 0, 10 * 1000 * 1000 }; /* 10 ms */
                note("boundary: guest closed the device; waiting for the next turn");
                in_boundary = 1;
                nanosleep(&ts, NULL);
            } else {
                struct timespec ts = { 0, 50 * 1000 * 1000 }; /* 50 ms */
                nanosleep(&ts, NULL);
            }
            continue;
        }
        in_boundary = 0;

        served++;
        note("turn %ld: request frame %llu bytes (header+body), consumed",
             served, fr.last_frame_bytes);

        /* The join runs FIRST: this frame's function_call_outputs answer the
         * calls decoded on EARLIER turns.  Then the OUTBOUND pass substitutes
         * the host's truth into the model-facing frame (restore + denial
         * text, keyed on the deny map) and RETURNS that frame — the exact
         * buffer a live lane sends; --dump-requests records the returned
         * frame.  Then the pending-substitution instrument flags any denial
         * whose substitution window just closed without firing, and finally
         * the decode gate judges the served stream at item completion — so a
         * call decoded on THIS turn is never resolved by THIS turn's own
         * frame, and its rewrite is decided BEFORE anything crosses. */
        join_pass(fr.body, fr.last_frame_body_len, served);
        char *out_frame = outbound_pass(fr.body, fr.last_frame_body_len, served);
        if (out_frame) {
            if (g_dump_path) {
                /* one compact JSON line per turn — the model-facing frame,
                 * AFTER the substitutions.  The dump records the RETURNED
                 * frame (what would be sent), never a second rendering. */
                FILE *f = fopen(g_dump_path, "a");
                if (!f) die_errno("cannot append --dump-requests");
                fwrite(out_frame, 1, strlen(out_frame), f);
                fputc('\n', f);
                if (fflush(f) != 0 || fsync(fileno(f)) != 0)
                    die_errno("fsync dump");
                fclose(f);
            }
            free(out_frame);
        }
        subst_unresolved_check(served);

        size_t served_len = 0;
        unsigned char *served_stream =
            serve_stream(upstream, upstream_len, served, &served_len);

        if (write_all(master, served_stream, served_len) != 0) {
            if (errno == EIO || errno == ENXIO || errno == EPIPE) {
                /* the guest breaks at response.completed and closes; a tail
                 * still queued at that moment dies here — a boundary, not an
                 * error (nothing after completed is ever parsed) */
                note("boundary: guest left mid-stream (errno=%d); stream tail dropped",
                     errno);
            } else {
                note("FATAL: upstream write failed (errno=%d)", errno);
                return 1;
            }
        } else {
            note("turn %ld: served %zu bytes", served, served_len);
        }
        free(served_stream);

        /* P5: the per-turn denial-rate instrument, emitted AFTER the decode
         * (the calls of this turn have been judged by now) and BEFORE the
         * turn ends — a row per armed turn, so the dead-agent shape is a
         * number in the record rather than an inference from a wall of
         * denials. */
        turn_stats_emit(served);

        if (max_turns >= 0 && served >= max_turns) break;
    }

    /* MEASURED: the pty ldisc's read buffer is small (4096), and master
     * writes beyond it are staged in kernel buffers that reach the reader
     * only as it drains.  EXITING NOW would close the master and FLUSH that
     * staged tail — the guest would see a silent truncation (it cannot tell
     * truncation from EOF: both end its read loop).  So the proxy holds the
     * master open until the guest's own turn-end close
     * (openai_responses.c:292), which arrives as EIO here: the reader is
     * done by definition once it has closed, and what it read is everything
     * it will ever read.  This is the same boundary mechanic (b), reused as
     * the exit cue. */
    for (;;) {
        fd_set rfds;
        struct timeval tv = { 10, 0 };
        FD_ZERO(&rfds);
        FD_SET(master, &rfds);
        int s = select(master + 1, &rfds, NULL, NULL, &tv);
        if (s <= 0) {
            note("exit: no guest close within 10s; exiting anyway");
            break;
        }
        int r = read_frame(master, &fr);
        if (r == 1) {
            note("boundary: guest closed the device; clean exit");
            break;
        }
        if (r == 0) {
            note("unexpected extra frame (%llu bytes) after the last turn; ignored",
                 fr.last_frame_bytes);
            continue;
        }
        note("FATAL: request frame protocol violation after the last turn");
        return 1;
    }

    /* THE VISIBILITY CONTRACT (P2): the record is closed explicitly — every
     * call still pending here is named on stderr AND in a terminal
     * proxy-exit summary row, so an unfireable join can never sit silent. */
    log_exit_report(served);

    note("done: %ld turn(s) served", served);
    free(upstream);
    free(fr.body);
    close(master);
    return 0;
}
