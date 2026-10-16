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
 *   brief's "deny get_weather").  The OPERATOR's real author arrives in P6
 *   (--ops-policy-dir, the pinned ops policy evaluated at this seat); the
 *   CLAIM author arrives in P7 (--calls-policy-dir, the pinned calls policy
 *   judged by shelling policy/calls/eval_calls.py).  The log's `author` field
 *   always names what ACTUALLY RAN — `denylist`, `ops`, `justification`,
 *   `claim` (or their `+`-joined set): a row claiming an author that did
 *   not run would be a record wider than the evidence.  With NO --deny, NO
 *   --require-justification, NO live --ops-policy-dir and NO live
 *   --calls-policy-dir, NO policy ran and
 *   NO verdict field is emitted (the P2 shape, byte-identical — its phases
 *   must stay green).  On an ALLOWED row `author` names the authors ARMED AND
 *   CONSULTED at this seat, which is not always the same as "evaluated THIS
 *   call": the ops judge returns before the policy is consulted for a verb it
 *   does not classify as a write, so an allowed row for such a verb names
 *   `ops` as armed, never as having judged the call (the review's secondary
 *   note, named here rather than widened into a per-call author field).
 *   AND AN ALLOW CARRIES ITS OWN READING: every ALLOWED row renders
 *   `allow_scope`, the seat-scoped qualifier that an allow means "no operator
 *   denial at this seat", never "the write is permitted" — in the RECORD,
 *   where a reader at rest (fx-audit, P9's join) can see it, not only in the
 *   startup line, which is transient.
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
 * P6 SCOPE — THE OPERATOR AUTHOR AT THE HOST SEAT.  The proxy gains the
 *   OPERATOR as a real policy author beside the P3 `--deny` placeholder
 *   denylist (which STAYS: many existing phases depend on it and it is
 *   honestly named).  --ops-policy-dir DIR loads the PINNED ops policy
 *   (policy/ops: PINS + ops-policy.dl + ops-aliases.tsv) and evaluates it per
 *   call, at the same place P3 decides.  THE WHOLE SECTION — the D1/D2 split
 *   determined from the rule text, how the split is ENFORCED (the seat loads
 *   the artifact whole and binds only host-derivable facts, so D2 is INERT BY
 *   CONSTRUCTION), the per-call class resolution and its canonicalization,
 *   the floor this seat does NOT have, and the startup obligations the
 *   in-guest seat's served set makes impossible here — is documented at the
 *   P6 section itself (search "P6: THE OPERATOR AUTHOR").  THE FAILURE
 *   DIRECTIONS the gate pins: a PRE-FIX seat that does not deny what the
 *   pinned policy denies is FAIL-OPEN (build/fx-hostgate-noops); a seat that
 *   binds the floor it cannot see OVER-DENIES (build/fx-hostgate-opsfloor);
 *   and a seat that matches the RAW path against the pinned patterns is a
 *   SILENT ALLOW on exactly the equivalent spellings the in-guest seat does
 *   deny (build/fx-hostgate-opsnocanon).
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
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#include "dhall.h" /* sha256_hex — the vendored dhall-c hash, P4's catalog pin
                    * (the same helper fx-verbs-server.c:985 checks PINS with;
                    * the Makefile links src/vendor/dhall-c/sha256.c only, as
                    * it already does for fx-audit/fx-report/fx-claim) */
#include "yyjson.h"
/* P6: THE SIBLING DATALOG ENGINE, linked IN-PROCESS the way the tree already
 * links it (the Makefile's $(BIN) rule, tools/build.sh for the verbs server,
 * src/runstore.h): the header resolves through build/include's symlink to the
 * ENGINE'S OWN src/ — the reasoning is never reimplemented in the proxy. */
#include "vendor/datalog-dafsa/src/dl.h"

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
/* declared here (redeclared with the calls seat below) because the log
 * writer's ALLOWED-row allow_scope must name the seat that acted */
static int calls_seat_present(void);
static void tb_put(struct tbuf *t, const char *s, size_t n);
static void tb_puts(struct tbuf *t, const char *s);
#ifndef FH_MUTANT_NO_DENIAL_RATE /* the instrument is the only caller */
static char *reasons_breakdown_json(const char *const *names,
                                    const size_t *counts, size_t n);
#endif

/* THE HONEST AUTHOR/REFUSAL NAMES (P3 + P5 + P6; see the P3/P5/P6 header
 * blocks).  P3's is a placeholder denylist; P5's is the justification check;
 * P6's is THE OPERATOR POLICY at this seat (the real second author), whose
 * refusal name follows the plan's salvaged list (`denied-by-ops`).  Every
 * denial names its author AND its reason, and the refusal is BY NAME (never a
 * bare rejection).  Declared here because the log writer below renders them. */
#define FH_AUTHOR_DENYLIST "denylist"
#define FH_REFUSAL_DENYLIST "denied-by-denylist"
#define FH_AUTHOR_JUSTIFY "justification"
#define FH_REFUSAL_ABSENT_JUSTIFY "absent-justification"
#define FH_REFUSAL_MALFORMED_JUSTIFY "malformed-justification"
#define FH_AUTHOR_OPS "ops"
#define FH_REFUSAL_OPS "denied-by-ops"
#define FH_AUTHOR_CLAIM "claim"
#define FH_REFUSAL_CLAIM "denied-by-claim"
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
            /* P3/P5/P6/P7: the verdict fields render ONLY when a policy actually
             * ran (the brief's honesty rule).  `author` names what ran — the
             * placeholder denylist, the ops policy at this seat (P6), the
             * claim policy at this seat (P7) and/or
             * the justification check; on a denial it names the ONE author that refused, and
             * refusal_name is the by-name refusal (P3's denied-by-denylist,
             * P5's absent-/malformed-justification, P6's denied-by-ops,
             * P7's denied-by-claim).
             * reason/denial_text are real exactly for a denial, explicit
             * nulls otherwise. */
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
                /* THE ALLOW CARRIES ITS OWN READING (P6-fix).  An allowed row
                 * means "no operator denial AT THIS SEAT", never "the write
                 * is permitted" — the qualifier used to live only in the
                 * stderr startup line, which is TRANSIENT, while the one log
                 * is what a reader (fx-audit, P9's join) sees AT REST.  So it
                 * is a FIELD on the row.  A NEW key, deliberately not
                 * `reason`: phase 12 asserts an allowed row's
                 * reason/refusal_name/denial_text are null, and reason is the
                 * denial's field — reusing it would make an allow look like a
                 * refusal.
                 *
                 * P7-fix: when the CLAIM author is live too, the qualifier
                 * names IT as well — the same row then also reads "no claim
                 * refusal at this seat", which is exactly what an allowed row
                 * with author `...claim...` means.  The P6 text alone
                 * under-described the seat's authority. */
                char *jscope = json_str(
                    calls_seat_present()
                    ? "seat-scoped: no operator denial and no claim refusal at "
                      "this seat (the justification was judged and derived); "
                      "the in-guest floor and D2 still govern"
                    : "seat-scoped: no operator denial at this seat; "
                      "the in-guest floor and D2 still govern");
                fprintf(f,
                        ",\"verdict\":\"allowed\",\"author\":%s,"
                        "\"allow_scope\":%s,"
                        "\"refusal_name\":null,\"reason\":null,"
                        "\"denial_text\":null}",
                        jauth, jscope);
                free(jscope);
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

/* P6's arm (--ops-policy-dir): the operator policy directory at the host seat.
 * ops_seat_present() is defined with the ops seat itself (below); it is the
 * seat's own answer to "did an author that can refuse actually run here?"
 * (loaded AND at least one rule is live at this seat). */
static int ops_seat_present(void);
static const char *g_ops_dir;
/* P7's arm (--calls-policy-dir): the claim-author policy directory at the host
 * seat.  calls_seat_present() is defined with the calls seat itself (below);
 * it is the seat's own answer to "did an author that can refuse actually run
 * here?" (loaded AND armed). */
static int calls_seat_present(void);
static const char *g_calls_dir;

/* ARMED = an author that can refuse is active.  The denylist (P3), the ops
 * policy at this seat (P6) and the justification check (P5) are three authors;
 * any one alone is armed. */
static int policy_armed(void) {
    return g_ndeny > 0 || g_require_justify || ops_seat_present()
           || calls_seat_present();
}

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

/* ── P6: THE OPERATOR AUTHOR at the HOST SEAT ─────────────────────────────── */
/*
 * The proxy gains the OPERATOR as a real policy author — the second of the
 * design's two visibly distinct authors (the operator says "you may not do
 * this"; P7's claim judgment says "this is not justified").  It REPLACES
 * NOTHING: the P3 --deny placeholder denylist stays exactly as it is.
 *
 * THIS IS A PORT of the in-guest ops seat (tools/fx-verbs-server.c:774-1573:
 * ops_verify_pins, ops_load_aliases, ops_pattern_valid/ops_pattern_hits,
 * ops_fold_proper, ops_resolve_and_declare, the fact injection and the
 * `denied` query), not a re-derivation.  ZERO GUEST CHANGE: the in-guest seat
 * is DEMOTED to the second line of defence and keeps D2.
 *
 * THE D1/D2 SPLIT, DETERMINED FROM THE RULE TEXT (policy/ops/ops-policy.dl —
 * the artifact, not a summary) AND NAMED IN THE STARTUP LINE:
 *
 *   D1  denied(W1,P1) :- touches(W1,P1), kind(W1,write), class(P1,C1),
 *                        protected(C1).
 *       Every body atom is derivable AT THIS SEAT: `touches` from the call's
 *       own arguments, `kind` static per verb, `class`/`protected` from the
 *       PINNED alias table (policy/ops/ops-aliases.tsv).  D1 IS EVALUABLE
 *       HERE.
 *
 *   D2  denied(W1,P1) :- touches(W1,P1), kind(W1,write), writable(P1),
 *                        !boot_verdict(ok).
 *       Needs `writable(P1)` — the compiled-in writable set, an in-guest fact
 *       of the verbs server's own FX_AGENT_WRITABLE env (fx-verbs-server.c:
 *       285-314, 1960-1976) — AND `!boot_verdict(ok)`, LIVE in-guest runtime
 *       state read from the bootlog (fx-verbs-server.c:1430-1438).  The host
 *       reads NEITHER: fx-audit/fx-claim read the store only AT REST, and the
 *       gate sees only the two chardev legs.  D2 STAYS IN-GUEST.
 *
 * HOW THE SPLIT IS ENFORCED RATHER THAN ASSERTED: this seat LOADS THE WHOLE
 * pinned artifact (both rules — the rule set is never filtered, so the
 * loaded policy IS the pinned policy) and injects ONLY the facts it can
 * derive: kind/touches/class/protected.  It NEVER injects `writable(...)` or
 * `boot_verdict(...)`, so D2's body has an unsatisfiable atom AT THIS SEAT
 * and the rule is INERT BY CONSTRUCTION.  The startup line NAMES each rule
 * as LIVE or INERT at this seat, with the reason — a seat that silently
 * omitted D2 while its logs read as though the policy were enforced is the
 * exact failure shape this project keeps paying for.
 *
 * THE FLOOR, HONESTLY: this seat has NO floor of its own and CANNOT mirror
 * one.  The floor is the verbs server's compiled-in writable set, a fact of
 * the GUEST's environment; the host never sees it.  So the floor — and D2,
 * which is conditioned on it — is ENFORCED IN-GUEST ONLY (by the demoted C
 * seat), and the startup line says so.  DENY-MORE-ONLY holds structurally
 * anyway: this seat can only ADD denials to the in-guest decision
 * (floor_allows && !denied_D2_guest && !denied_D1_host) — it has no
 * vocabulary and no code path that could grant anything.
 *
 * THE PER-CALL RESOLUTION (the timing difference from the in-guest seat,
 * stated because it is what the port had to get right): the in-guest seat
 * resolves `class` at STARTUP against the SERVED path set (the canonicalized
 * writable-set entries).  At the host the target path is PER CALL — it
 * arrives in the call's arguments — so `class(<call's path>, <class>)` is
 * injected per call, matched with the SAME two-form pattern grammar against
 * the SAME pinned table.  THE SEMANTICS ARE THE SAME because the path is
 * CANONICALIZED THE SAME WAY FIRST (canon_root_rel's lexical normalization,
 * fx-verbs-server.c:388-418, re-implemented below as fh_canon_abs): a call
 * spelling the protected path as "/fx/disk/agent-data/../agent-config.dhall"
 * must be denied here exactly as it is denied in-guest.  A raw string
 * comparison against the pattern would MISS it — a host-seat silent allow
 * (the in-guest seat would still refuse the write, so nothing would execute;
 * but the host's own job is to decide, and the gate pins the canonicalizing
 * behaviour with a mutant that does not canonicalize).
 *
 * ONE HONEST DIFFERENCE THAT CANNOT BE PORTED, named: the in-guest seat's
 * STARTUP obligations run against a SERVED SET — "a PROTECTED alias matching
 * NO served path" and "a SERVED path covered by NO row" are both loud
 * refusals there (fx-verbs-server.c:1187-1266).  This seat has no served set
 * (the wired paths are a guest-env fact), so it cannot make either check and
 * DOES NOT CLAIM TO.  An unclassified path at this seat simply acquires no
 * `class` fact: untightened, not loosened — the in-guest floor and D2 still
 * govern, and the in-guest seat still refuses loudly if its own served set
 * goes uncovered.
 *
 * THE BINDING, MEASURED AGAINST THE C SEAT RATHER THAN ASSUMED: the verb whose
 * path this seat binds is fx_write (the one name the in-guest dispatch reads
 * `path` from — fx-verbs-server.c:2680-2684; `content` is irrelevant to the
 * policy), and the fact the policy speaks about is `touches(<verb>,<path>)`
 * with the SAME guest-absolute spelling the pinned patterns are written in.
 * TWO SHAPES NAMED, not hidden: (a) the SUBTREE pattern form's grandchild case
 * cannot arise IN-GUEST at all — the floor is EXACT-match, so no grandchild
 * ever reaches the commit site — which is exactly why the grammar is
 * re-checked HERE (the pinned TABLE is the authority and the in-guest seat
 * validates it at its own startup); (b) the never-opened-done shape (a
 * function_call whose `added` never arrived) is judged at this seat on the
 * done item's own `arguments` field, exactly as P3 and P5 judge it there:
 * the guest dispatches NOTHING for that shape (its accumulator is fed by the
 * added event alone), so the judgement is a refusal of a call that could not
 * have executed — the pre-existing P3 shape, inherited, not newly introduced.
 *
 * THE PIN (ported verbatim in discipline): every file policy/ops/PINS names
 * must exist with the pinned sha256, verified AT STARTUP before any denial is
 * believed; the verified bytes are KEPT and handed to the loaders (no window
 * for a swap between hash and load).  A stale or swapped artifact is a LOUD
 * STARTUP REFUSAL naming both shas.  An ABSENT --ops-policy-dir is the NAMED
 * "no operator author at this seat" state, never an error.  ONE DELIBERATE
 * DIFFERENCE from the in-guest seat: --ops-policy-dir is EXPLICIT, so a dir
 * the operator NAMES but that carries no verifiable PINS refuses loudly, where
 * the in-guest seat (whose dir is a well-known staging point) treats an
 * absent-or-EMPTY dir as the named floor-only state.
 */
#define FH_OPS_DL       "ops-policy.dl"
#define FH_OPS_TSV      "ops-aliases.tsv"
#define FH_OPS_PINS     "PINS"
#define FH_OPS_MAX_FILE (1024u * 1024u) /* the artifact cap, FXV_OPS_MAX_FILE's */

#ifndef FH_MUTANT_NO_OPS_SEAT
/* THE WRITE-VERB SET — the verbs whose `kind(W, write)` fact this seat
 * injects.  PINNED HERE, and the pin is checkable: the in-guest seat is
 * consulted from EXACTLY ONE commit site, native_write
 * (fx-verbs-server.c:1983, the only `!ops_write_allowed(` call), and that
 * site writes exactly one verb's path.  The gate re-checks that provenance
 * against the guest source, so a second write verb added in-guest surfaces as
 * a gate failure instead of as a verb this seat silently does not bind (a
 * silent allow of the deny-more-only direction). */
static const char fh_ops_write_verbs[] = "fx_write\n";
#define FH_OPS_WRITE_PROVENANCE "tools/fx-verbs-server.c:1983 native_write (the ONE !ops_write_allowed call site)"

/* Two DERIVED predicates this seat can never inject, and therefore the mark
 * of a rule that is INERT here.  A rule whose body names either cannot fire
 * on facts this seat adds — see the D1/D2 block above. */
static const char *const FH_OPS_UNSEEN[] = { "writable", "boot_verdict" };
#endif /* !FH_MUTANT_NO_OPS_SEAT */

typedef struct {
    char *alias;        /* the raw tsv surface, for the refusals */
    char *alias_folded; /* its FOLDED symbol (le's proper-noun fold) */
    char *pathclass;    /* the raw surface, for the refusals */
    char *class_sym;    /* FOLDED — the symbol the class/protected facts carry */
    int   prot;         /* the protected flag D1's protected(C1) rides on */
    char *pattern;      /* EXACT '<path>' or the SUBTREE form: <path> slash star star */
} FhOpsRow;

static struct {
    int   loaded;   /* a policy dir was given AND every startup check passed */
    int   present;  /* ...AND at least one rule is LIVE at this seat */
    char  dir[PATH_MAX];
    dl_db *db;
    char  scratch[PATH_MAX];
    char  sha[65];      /* the pinned .dl sha */
    char *dl_text;      /* the artifact's bytes (the verified ones) */
    char **rule;        /* its rule lines, for the per-rule attribution */
    size_t n_rule;
    size_t n_live;      /* rules this seat can evaluate */
    size_t n_inert;     /* rules naming a predicate this seat cannot inject */
    char  inert[256];   /* their positional names, for the startup line */
    char  live[256];    /* the LIVE rules' positional names */
    FhOpsRow *row;
    size_t n_row;
} OPS;

/* "Did an author that CAN REFUSE actually run at this seat?" — the honesty
 * rule's question (policy_armed, authors_ran).  A policy that loaded but has
 * no live rule here has no host-side contribution and must NOT be claimed as
 * an author that ran.  Compiled out entirely in the pre-fix control. */
static int ops_seat_present(void) {
#ifdef FH_MUTANT_NO_OPS_SEAT
    return 0;
#else
    return OPS.present;
#endif
}

#ifndef FH_MUTANT_NO_OPS_SEAT
/* ── the seat's internals (compiled out entirely in the pre-fix control) ─── */

/* A LOUD startup refusal, before the slave path is published: the ops seat
 * has no later moment at which a wrong policy load could be made visible. */
static void ops_gate_die(const char *fmt, ...) {
    fputs("fx-hostgate: ops-policy REFUSED: ", stderr);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    exit(1);
}

/* Best-effort scratch removal (flat engine files; no shell, no system(3)) —
 * the in-guest seat's ops_rm_rf discipline: the scratch db is
 * process-lifetime state and must not outlive the process. */
static void ops_rm_rf(const char *dir, int depth) {
    DIR *d = opendir(dir);
    if (!d) return;
    struct dirent *de;
    while ((de = readdir(d)) != NULL) {
        if (strcmp(de->d_name, ".") == 0 || strcmp(de->d_name, "..") == 0) continue;
        char *child = xmalloc(strlen(dir) + 1 + strlen(de->d_name) + 1);
        sprintf(child, "%s/%s", dir, de->d_name);
        if (unlink(child) != 0 && errno == EISDIR && depth < 4)
            ops_rm_rf(child, depth + 1);
        free(child);
    }
    closedir(d);
    rmdir(dir);
}

/* STATED RESIDUAL: this runs at process exit (atexit) and on every normal
 * path, so a proxy that finishes removes its scratch db.  A proxy killed by a
 * SIGNAL does not run it and leaves the scratch dir under $TMPDIR behind —
 * the in-guest seat's ops_policy_shutdown has exactly the same shape (atexit,
 * the same signal hole), and the dir holds only this process' own policy
 * state, never anything in the store or in a writable set.  Named, not
 * hidden. */
static void ops_shutdown(void) {
    if (OPS.db) { dl_close(OPS.db); OPS.db = NULL; }
    if (OPS.scratch[0]) { ops_rm_rf(OPS.scratch, 0); OPS.scratch[0] = '\0'; }
}

/* Read a whole file, or NULL (errno set; EFBIG when over the cap). */
static char *ops_read_file(const char *path, size_t *len_out) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    size_t cap = 8192, len = 0;
    char *buf = malloc(cap + 1);
    if (!buf) { fclose(f); return NULL; }
    for (;;) {
        if (len == cap) {
            if (cap >= FH_OPS_MAX_FILE) {
                errno = EFBIG; /* named as a read failure, not a stale errno */
                free(buf); fclose(f); return NULL;
            }
            cap *= 2;
            char *nb = realloc(buf, cap + 1);
            if (!nb) { free(buf); fclose(f); return NULL; }
            buf = nb;
        }
        size_t n = fread(buf + len, 1, cap - len, f);
        len += n;
        if (n == 0) break;
    }
    if (ferror(f)) { free(buf); fclose(f); return NULL; }
    fclose(f);
    buf[len] = '\0';
    if (len_out) *len_out = len;
    return buf;
}

/* THE PIN CHECK (ported): every file PINS names must exist with the pinned
 * sha256; the two files the seat LOADS must be pinned at all; the verified
 * bytes are the bytes the loaders receive.  Names BOTH shas on a mismatch —
 * the operator's diagnosis is "which bytes did I expect vs which am I
 * holding". */
static void ops_verify_pins(const char *dir, const char *pins_path,
                            char **dl_out, char **tsv_out, char *dl_sha_out) {
    size_t plen = 0;
    char *pins = ops_read_file(pins_path, &plen);
    if (!pins)
        ops_gate_die("%s cannot be read: %s — a present policy dir must carry "
                     "a verifiable pin set", pins_path, strerror(errno));
    int saw_dl = 0, saw_tsv = 0;
    char *save = NULL;
    for (char *line = strtok_r(pins, "\n", &save); line;
         line = strtok_r(NULL, "\n", &save)) {
        while (*line == ' ' || *line == '\t') line++;
        if (!*line || *line == '#') continue;
        char *tab = strchr(line, '\t');
        if (!tab)
            ops_gate_die("%s: a pin row is name<TAB>sha256, got '%.80s'",
                         pins_path, line);
        *tab = '\0';
        char *name = line, *want = tab + 1;
        char *cr = strchr(want, '\r');
        if (cr) *cr = '\0';
        int is_dl = strcmp(name, FH_OPS_DL) == 0;
        int is_tsv = strcmp(name, FH_OPS_TSV) == 0;
        if (is_dl) saw_dl = 1;
        if (is_tsv) saw_tsv = 1;
        char path[PATH_MAX];
        int n = snprintf(path, sizeof path, "%s/%s", dir, name);
        if (n <= 0 || n >= (int)sizeof path)
            ops_gate_die("pin path too long: %s", name);
        size_t flen = 0;
        char *bytes = ops_read_file(path, &flen);
        if (!bytes)
            ops_gate_die("pinned file %s is MISSING or unreadable (: %s) "
                         "(pinned sha256 %s) — no such file, or it is over the "
                         "%u-byte artifact cap; restore it or re-pin",
                         path, strerror(errno), want, FH_OPS_MAX_FILE);
        char got[65];
        sha256_hex(bytes, flen, got);
        if (strcmp(got, want) != 0) {
            free(bytes);
            ops_gate_die("pinned file %s sha256 mismatch: pinned %s != actual "
                         "%s — the deployed artifact is stale or swapped; a "
                         "policy edit is a re-pin (artifact + PINS in the same "
                         "release)", path, want, got);
        }
        if (is_dl) {
            free(*dl_out);
            *dl_out = bytes;
            snprintf(dl_sha_out, 65, "%s", want);
        } else if (is_tsv) {
            free(*tsv_out);
            *tsv_out = bytes;
        } else {
            free(bytes);
        }
    }
    free(pins);
    if (!saw_dl || !saw_tsv)
        ops_gate_die("%s does not pin both %s and %s — the loaded artifacts "
                     "would go unverified", pins_path, FH_OPS_DL, FH_OPS_TSV);
}

/* THE PATTERN GRAMMAR — the TWO FORMS ops-aliases.tsv states and
 * eval_ops.py --check-aliases enforces at pin time, RE-RUN AT THIS SEAT (the
 * seat does not trust the staging to have been checked, and a previous review
 * found this exact grammar broken once: patterns were exact-match globs while
 * validation checked only absoluteness, so a rule that LOOKED protective
 * never fired for any child — an operator-reachable SILENT ALLOW).
 *   EXACT   '<path>'  glob-less; matches that one path, NEVER a prefix
 *   SUBTREE           '<path>' plus a slash and two asterisks: the path
 *                     itself and every descendant
 * Anything else (a lone '*', '?', '[', '**' off the tail, a trailing '/', a
 * subtree base ending in '/') is a LOUD refusal: coverage nobody stated is
 * the silent allow-all. */
static int ops_glob_char(const char *s) { return strpbrk(s, "*?[") != NULL; }

static int ops_pattern_valid(const char *p) {
    size_t l = strlen(p);
    if (l < 2 || p[0] != '/') return 0;
    if (l >= 3 && strcmp(p + l - 3, "/**") == 0) {
        size_t bl = l - 3;
        if (bl < 2 || p[0] != '/' || p[bl - 1] == '/') return 0;
        char base[PATH_MAX];
        if (bl >= sizeof base) return 0;
        memcpy(base, p, bl); base[bl] = '\0';
        return !ops_glob_char(base);
    }
    if (p[l - 1] == '/') return 0;
    return !ops_glob_char(p);
}

static int ops_pattern_hits(const char *pattern, const char *canon) {
    size_t pl = strlen(pattern);
    if (pl >= 3 && strcmp(pattern + pl - 3, "/**") == 0) {
        size_t bl = pl - 3;
        size_t cl = strlen(canon);
        if (cl < bl || strncmp(canon, pattern, bl) != 0) return 0;
        return cl == bl || canon[bl] == '/';
    }
    return strcmp(canon, pattern) == 0;
}

/* THE FOLD (the folding contract's seat half): le compiles a proper noun to
 * its LOWERCASED dl symbol, so the seat folds the table's surfaces before
 * interning — an unfolded surface could only ever non-match a legal rule's
 * folded constant (a policy that stops matching stops protecting, silently).
 * A non-ASCII-letters surface is REFUSED rather than folded: le could never
 * compile it into a constant. */
static int ops_fold_proper(char *dst, size_t dstsz, const char *src) {
    size_t l = strlen(src);
    if (l == 0 || l >= dstsz) return 0;
    for (size_t i = 0; i < l; i++) {
        unsigned char c = (unsigned char)src[i];
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z'))) return 0;
        dst[i] = (char)(c | 0x20);
    }
    dst[l] = '\0';
    return 1;
}

/* The alias table: alias<TAB>pathclass<TAB>protected<TAB>pattern, '#'
 * comments — parsed and VALIDATED here (grammar above, duplicate aliases, the
 * yes/no flag, proper-noun surfaces), because a malformed row must refuse
 * loudly, never half-match.  `tsv_owned` is the verified bytes the pin check
 * kept. */
static void ops_load_aliases(const char *path, char *tsv_owned) {
    char *tsv = tsv_owned;
    size_t cap = 8;
    OPS.row = xmalloc(cap * sizeof *OPS.row);
    char *save = NULL;
    for (char *line = strtok_r(tsv, "\n", &save); line;
         line = strtok_r(NULL, "\n", &save)) {
        while (*line == ' ' || *line == '\t') line++;
        size_t ll = strlen(line);
        if (ll > 0 && line[ll - 1] == '\r') line[ll - 1] = '\0';
        if (!*line || *line == '#') continue;
        char *f[4];
        int nf = 0;
        char *lsave = NULL;
        for (char *tok = strtok_r(line, "\t", &lsave); tok && nf < 4;
             tok = strtok_r(NULL, "\t", &lsave))
            f[nf++] = tok;
        if (nf != 4)
            ops_gate_die("%s: an alias row is alias<TAB>pathclass<TAB>protected"
                         "<TAB>pattern, got %d field(s)", path, nf);
        if (strcmp(f[2], "yes") != 0 && strcmp(f[2], "no") != 0)
            ops_gate_die("%s: the protected flag is '%s', not yes|no", path, f[2]);
        if (!ops_pattern_valid(f[3]))
            ops_gate_die("%s: the pattern '%s' is neither of the two stated "
                         "forms — an EXACT glob-less path or a SUBTREE "
                         "'<path>/**'; an ambiguous glob covers a set nobody "
                         "stated, and a pattern that matches nothing is a "
                         "silent allow-all", path, f[3]);
        if (OPS.n_row == cap) {
            cap *= 2;
            OPS.row = realloc(OPS.row, cap * sizeof *OPS.row);
            if (!OPS.row) die_errno("realloc alias rows");
        }
        FhOpsRow *r = &OPS.row[OPS.n_row];
        memset(r, 0, sizeof *r);
        r->alias = xstrdup(f[0]);
        r->pathclass = xstrdup(f[1]);
        r->pattern = xstrdup(f[3]);
        r->alias_folded = xmalloc(strlen(f[0]) + 1);
        r->class_sym = xmalloc(strlen(f[1]) + 1);
        if (!ops_fold_proper(r->alias_folded, strlen(f[0]) + 1, f[0]))
            ops_gate_die("%s: the alias '%s' is not a proper noun (ASCII "
                         "letters only) — le compiles proper nouns to their "
                         "lowercased symbol, so any other shape could only ever "
                         "match nothing", path, f[0]);
        if (!ops_fold_proper(r->class_sym, strlen(f[1]) + 1, f[1]))
            ops_gate_die("%s: the pathclass '%s' is not a proper noun (ASCII "
                         "letters only)", path, f[1]);
        for (size_t i = 0; i < OPS.n_row; i++)
            if (strcmp(OPS.row[i].alias_folded, r->alias_folded) == 0)
                ops_gate_die("%s: the alias '%s' is mapped twice", path, f[0]);
        r->prot = (strcmp(f[2], "yes") == 0);
        OPS.n_row++;
    }
    free(tsv);
    if (OPS.n_row == 0)
        ops_gate_die("%s carries no alias rows — the vocabulary seam's binding "
                     "table is empty and every path would be unclassified", path);
}

/* THE PATH CANONICALIZATION, px-ported from the in-guest seat's
 * canon_root_rel + ops_abs_of (fx-verbs-server.c:388-418, 1170-1177): resolve
 * "." and ".." components lexically and drop empty ones; a ".." that climbs
 * above the root, or a non-absolute spelling, yields NULL.  THE RESULT IS THE
 * ABSOLUTE GUEST-ABSOLUTE SPELLING the pinned alias patterns are written in,
 * so matching here is the SAME match the in-guest seat makes — a raw string
 * comparison would miss every equivalent spelling (a host-seat silent allow).
 * Returns a malloc'd string, or NULL. */
#ifndef FH_MUTANT_OPS_NO_CANON
static char *fh_canon_abs(const char *abs) {
    if (!abs || abs[0] != '/') return NULL;
    size_t cap = strlen(abs) + 2;
    char *out = xmalloc(cap);
    size_t olen = 0;
    int depth = 0;
    const char *p = abs;
    while (*p) {
        while (*p == '/') p++;
        if (!*p) break;
        const char *seg = p;
        while (*p && *p != '/') p++;
        size_t sl = (size_t)(p - seg);
        if (sl == 1 && seg[0] == '.') continue;
        if (sl == 2 && seg[0] == '.' && seg[1] == '.') {
            if (depth == 0) { free(out); return NULL; } /* escapes the root */
            while (olen > 0 && out[olen - 1] != '/') olen--;
            if (olen > 0) olen--;
            depth--;
            continue;
        }
        if (olen + sl + 2 >= cap) { free(out); return NULL; }
        out[olen++] = '/';
        memcpy(out + olen, seg, sl);
        olen += sl;
        depth++;
    }
    if (olen == 0) out[olen++] = '/'; /* the root itself */
    out[olen] = '\0';
    return out;
}
#endif /* !FH_MUTANT_OPS_NO_CANON */

/* How many write verbs the pinned set names (the startup line counts rather
 * than asserting a literal). */
static size_t ops_write_verb_count(void) {
    size_t n = 0;
    for (const char *p = fh_ops_write_verbs; *p; p++) {
        if (*p == '\n') n++;
    }
    return n;
}

/* Is `name` a verb this seat injects kind(<verb>, write) for? */
static int ops_write_verb(const char *name) {
    if (!name || !*name) return 0;
    const char *p = fh_ops_write_verbs;
    while (*p) {
        const char *e = strchr(p, '\n');
        if (!e) break;
        size_t l = (size_t)(e - p);
        if (strlen(name) == l && strncmp(name, p, l) == 0) return 1;
        p = e + 1;
    }
    return 0;
}

/* Split the artifact's rule lines (one per line, the deterministic compile)
 * for the per-rule attribution and the LIVE/INERT classification.  A rule
 * whose BODY names a predicate this seat can never inject is INERT here —
 * named, never silently dropped from the artifact. */
static void ops_classify_rules(void) {
    for (char *p = OPS.dl_text; *p; ) {
        while (*p == '\n' || *p == '\r' || *p == ' ' || *p == '\t') p++;
        if (!*p) break;
        char *end = p;
        while (*end && *end != '\n' && *end != '\r') end++;
        int ended = *end != '\0';
        *end = '\0';
        if (!ended) end = NULL;
        OPS.rule = realloc(OPS.rule, (OPS.n_rule + 1) * sizeof *OPS.rule);
        if (!OPS.rule) die_errno("realloc rule lines");
        OPS.rule[OPS.n_rule++] = p;
        if (!end) break;
        p = end + 1;
    }
    if (OPS.n_rule == 0)
        ops_gate_die("%s carries no rules (policy-vacuous) — an artifact the "
                     "release path's lint refuses cannot be served as a policy",
                     FH_OPS_DL);

    for (size_t i = 0; i < OPS.n_rule; i++) {
        const char *body = strchr(OPS.rule[i], ':');
        int unseen = 0;
        if (body) {
            for (size_t k = 0; k < sizeof FH_OPS_UNSEEN / sizeof *FH_OPS_UNSEEN; k++) {
                size_t nl = strlen(FH_OPS_UNSEEN[k]);
                char needle[64];
                snprintf(needle, sizeof needle, "%s(", FH_OPS_UNSEEN[k]);
                (void)nl;
                if (strstr(body, needle)) { unseen = 1; break; }
            }
        }
        char *dst = unseen ? OPS.inert : OPS.live;
        char nm[24];
        snprintf(nm, sizeof nm, "%sD%zu", dst[0] ? "," : "", i + 1);
        size_t used = strlen(dst);
        if (used + strlen(nm) < 200) strcat(dst, nm);
        if (unseen) OPS.n_inert++;
        else OPS.n_live++;
    }
    /* PRESENT means an author that can actually refuse is active: a policy
     * whose every rule is INERT here has no host-side contribution, and this
     * seat must not claim one (see the honesty rule). */
    OPS.present = OPS.n_live > 0;
    if (OPS.loaded && !OPS.present)
        note("ops-policy: %zu rule(s) loaded, NONE live at this seat (%s are "
             "inert here: they need facts this seat never injects) — the "
             "operator author does NOT act at this seat; the in-guest seat "
             "alone enforces this policy", OPS.n_rule,
             OPS.inert[0] ? OPS.inert : "(all)");
}

/* The fact-count collector (dl_tuple_cb): the query's only job here is
 * "does a denial derive", so it counts rows. */
static int ops_count_cb(const uint32_t *cols, uint8_t arity, void *u) {
    (void)cols; (void)arity;
    (*(size_t *)u)++;
    return 0;
}


/* The real startup: only built when the seat exists. */
static void ops_seat_load(const char *dir) {
    struct stat st;
    if (stat(dir, &st) != 0 || !S_ISDIR(st.st_mode))
        ops_gate_die("%s is not a readable directory — a --ops-policy-dir must "
                     "name the directory holding %s, %s and %s",
                     dir, FH_OPS_PINS, FH_OPS_DL, FH_OPS_TSV);
    snprintf(OPS.dir, sizeof OPS.dir, "%s", dir);

    char pins_path[PATH_MAX], tsv_path[PATH_MAX];
    snprintf(pins_path, sizeof pins_path, "%s/%s", dir, FH_OPS_PINS);
    snprintf(tsv_path, sizeof tsv_path, "%s/%s", dir, FH_OPS_TSV);
    char *tsv_bytes = NULL;
    ops_verify_pins(dir, pins_path, &OPS.dl_text, &tsv_bytes, OPS.sha);
    ops_load_aliases(tsv_path, tsv_bytes);

    /* the scratch db: process-lifetime state, removed at exit.  A HOST temp
     * dir (never the store, never the guest's /run — this seat is host-side). */
    const char *tmp = getenv("TMPDIR");
    if (!tmp || !*tmp) tmp = "/tmp";
    int n = snprintf(OPS.scratch, sizeof OPS.scratch, "%s/fx-hostgate-ops-XXXXXX", tmp);
    if (n <= 0 || n >= (int)sizeof OPS.scratch)
        ops_gate_die("cannot build the policy scratch db path under %s", tmp);
    if (!mkdtemp(OPS.scratch))
        ops_gate_die("cannot create the policy scratch db under %s: %s — a "
                     "present policy must be loadable, never silently skipped",
                     OPS.scratch, strerror(errno));
    atexit(ops_shutdown);
    int derr = 0;
    OPS.db = dl_open2(OPS.scratch, &derr);
    if (!OPS.db)
        ops_gate_die("cannot open the policy scratch db %s (err %d)", OPS.scratch, derr);

    /* THE CLOSED RELATION SET — exactly the ops lexicon's templates plus the
     * one head (ops-lexicon.ini [predicates]).  A pinned artifact whose atoms
     * fall outside it fails dl_load_rules BY NAME (the engine refuses an
     * undeclared predicate), so relation-level drift is loud.  It is DECLARED
     * even where this seat never adds a fact (writable, boot_verdict): the
     * artifact is loaded whole, and it is the BINDING, not the relation set,
     * that makes D2 inert. */
    if (dl_declare_relation(OPS.db, "denied", 2) != 0 ||
        dl_declare_relation(OPS.db, "touches", 2) != 0 ||
        dl_declare_relation(OPS.db, "kind", 2) != 0 ||
        dl_declare_relation(OPS.db, "class", 2) != 0 ||
        dl_declare_relation(OPS.db, "protected", 1) != 0 ||
        dl_declare_relation(OPS.db, "writable", 1) != 0 ||
        dl_declare_relation(OPS.db, "boot_verdict", 1) != 0)
        ops_gate_die("cannot declare the closed relation set in %s", OPS.scratch);
    if (dl_load_rules(OPS.db, OPS.dl_text) != 0)
        ops_gate_die("%s/%s: the engine refused the pinned rules (see the "
                     "engine's diagnostic above) — a pinned artifact the engine "
                     "cannot load is a broken release, never a silent skip",
                     dir, FH_OPS_DL);

    OPS.loaded = 1;
    ops_classify_rules();

    /* THE STATIC FACTS — kind(<write verb>, write) for every verb in the
     * pinned write-verb set.  The verb must be in the proxy's own pinned
     * catalog: a write verb this proxy has never heard of would be a binding
     * nothing can consult, and it is cheap to make that loud. */
    {
        char vb[128];
        const char *p = fh_ops_write_verbs;
        while (*p) {
            const char *e = strchr(p, '\n');
            if (!e) break;
            size_t l = (size_t)(e - p);
            if (l >= sizeof vb) ops_gate_die("a write-verb entry is too long");
            memcpy(vb, p, l); vb[l] = '\0';
            int in_catalog = 0;
            size_t cn = fh_catalog_count();
            for (size_t i = 0; i < cn; i++) {
                char nm[128];
                if (fh_catalog_nth(i, nm, sizeof nm) && strcmp(nm, vb) == 0) {
                    in_catalog = 1;
                    break;
                }
            }
            if (!in_catalog)
                ops_gate_die("the write-verb set names \"%s\", which is not in "
                             "the proxy's pinned verb catalog — a write verb the "
                             "catalog does not know is a binding nothing can "
                             "consult (%s)", vb, FH_OPS_WRITE_PROVENANCE);
            uint32_t k[2] = { dl_intern_str(OPS.db, vb),
                              dl_intern_str(OPS.db, "write") };
            if (!k[0] || !k[1] || dl_add_fact(OPS.db, "kind", k, 2) < 0)
                ops_gate_die("cannot inject the kind fact for %s (the folding "
                             "contract is machine-checked: a failed add refuses, "
                             "never silently proceeds)", vb);
            p = e + 1;
        }
    }

    /* THE STARTUP-HALF FACTS — protected(<class>) for every protected=yes row.
     * class-level, exactly as the in-guest seat injects it; the per-call
     * class(<path>,<class>) facts are what make it bite (D1 needs BOTH for
     * the SAME path). */
    for (size_t i = 0; i < OPS.n_row; i++) {
        if (!OPS.row[i].prot) continue;
        uint32_t pf[1] = { dl_intern_str(OPS.db, OPS.row[i].class_sym) };
        if (!pf[0] || dl_add_fact(OPS.db, "protected", pf, 1) < 0)
            ops_gate_die("cannot inject the protected fact for %s",
                         OPS.row[i].pathclass);
    }
}

/* STARTUP: the whole policy load, or one of the two NAMED states (no policy
 * given; a policy none of whose rules is live at this seat).  Called from
 * main() BEFORE the slave path is published, so every refusal is early. */
static void ops_seat_startup(const char *dir) {
    memset(&OPS, 0, sizeof OPS);
    if (!dir) {
        /* THE NAMED "NO OPERATOR AUTHOR AT THIS SEAT" STATE: not an error,
         * never a silent allow-all — the in-guest floor and D2 still govern,
         * and the P3 denylist is unaffected. */
        note("ops-policy: NONE — no --ops-policy-dir was given, so the "
             "operator author does not act at this seat (the in-guest seat "
             "still enforces the floor; this is a per-seat state, not an "
             "error)");
        return;
    }
    ops_seat_load(dir);
#ifdef FH_MUTANT_OPS_BIND_UNSEEN
    note("ops-policy: MUTANT (FH_MUTANT_OPS_BIND_UNSEEN) — this build ALSO "
         "injects writable(<path>) per call: THE FLOOR FACT THIS SEAT CANNOT "
         "SEE.  D2-class rules therefore FIRE here and the seat denies writes "
         "the real build allows — it is the D2-bound control, not a seat that "
         "claims a floor.");
#endif
#ifdef FH_MUTANT_OPS_NO_CANON
    note("ops-policy: MUTANT (FH_MUTANT_OPS_NO_CANON) — the call's RAW path "
         "string is matched against the pinned patterns: an equivalent "
         "spelling of a protected path is NOT denied at this seat");
#endif
    note("ops-policy: seat %s — %zu rule(s) loaded from the pinned artifact "
         "(sha256 %.16s..), %zu LIVE at this seat (%s), %zu INERT here (%s); "
         "%zu alias row(s), %zu write verb(s) bound",
         OPS.present ? "ARMED" : "LOADED-BUT-INERT",
         OPS.n_rule, OPS.sha, OPS.n_live, OPS.live[0] ? OPS.live : "(none)",
         OPS.n_inert, OPS.inert[0] ? OPS.inert : "(none)", OPS.n_row,
         ops_write_verb_count());
    if (OPS.present) {
        note("ops-policy: LIVE AT THIS SEAT (%s) — a rule whose body needs only "
             "the facts this seat can DERIVE.  Facts injected: "
             "kind(<write verb>,write) at startup; touches(<verb>,<canon path>) "
             "and class(<canon path>,<class>) PER CALL (the target path is in "
             "the call's arguments, canonicalized before matching) against the "
             "pinned alias table; protected(<class>) at startup for every "
             "protected=yes row.  D1 is the rule class this seat can evaluate.",
             OPS.live);
        note("ops-policy: INERT AT THIS SEAT (%s) — loaded from the SAME pinned "
             "artifact, but it CANNOT fire here: this seat never injects "
             "writable(...) (the compiled-in writable set is an IN-GUEST fact "
             "of the verbs server's own environment) and never injects "
             "boot_verdict(...) (LIVE in-guest runtime state, which no "
             "host-side reader can see — fx-audit/fx-claim read the store only "
             "AT REST).  D2 STAYS IN-GUEST, enforced by the demoted C seat "
             "(tools/fx-verbs-server.c).",
             OPS.inert[0] ? OPS.inert : "(none)");
        note("ops-policy: THE FLOOR — this seat has NO floor of its own and "
             "does not claim one: the compiled-in writable set is enforced "
             "IN-GUEST ONLY.  This seat can only ADD denials to the in-guest "
             "decision (deny-more-only holds structurally: it has no rule "
             "vocabulary and no code path that could grant); an ALLOW from this "
             "seat means 'no operator denial at this seat', never 'the write is "
             "permitted'.");
    }
}

#else /* FH_MUTANT_NO_OPS_SEAT */

/* P6 PRE-FIX CONTROL (build/fx-hostgate-noops): the ops seat is compiled OUT
 * while --ops-policy-dir is still ACCEPTED and IGNORED, so the build runs
 * exactly the P3-era proxy.  DIRECTION: FAIL-OPEN — a policy that DENIES in
 * the artifact does not deny at this seat (the true name crosses and the call
 * executes).  Asserted by the gate's control arm. */
static void ops_seat_startup(const char *dir) {
    memset(&OPS, 0, sizeof OPS);
    if (dir)
        note("ops-policy: SEAT COMPILED OUT (FH_MUTANT_NO_OPS_SEAT) — the "
             "policy dir %s is ACCEPTED AND IGNORED: this is the PRE-FIX "
             "control, the ops author does NOT run, and a call the pinned "
             "policy denies will CROSS and EXECUTE", dir);
    else
        note("ops-policy: SEAT COMPILED OUT (FH_MUTANT_NO_OPS_SEAT)");
}

#endif /* FH_MUTANT_NO_OPS_SEAT */

/* THE PER-CALL DECISION.  Returns 1 when this seat DENIES (filling `why`),
 * 0 when it is SILENT (it never permits — silence means "no operator denial
 * at this seat", and the in-guest floor + D2 still govern).  Injects the
 * per-call facts, queries the pinned rules, retracts the facts
 * (collect-then-mutate, the runstore.h discipline — the retraction also
 * retracts the derived rows, so nothing latches across calls). */
#ifndef FH_MUTANT_NO_OPS_SEAT
static int ops_judge(const char *name, const char *args, char *why, size_t whycap) {
    if (!OPS.present) return 0;
    if (!ops_write_verb(name)) return 0;

    /* THE PATH — the per-call binding the in-guest seat resolves at startup.
     * Extracted from the call's arguments BY KEY (the guest's own discipline,
     * fx-verbs-server.c:2548-2557: every verb extracts by key) and
     * CANONICALIZED before matching, so an equivalent spelling of a protected
     * path is denied here exactly as it is denied in-guest. */
    if (!args || !*args) return 0;
    yyjson_doc *doc = yyjson_read(args, strlen(args), 0);
    yyjson_val *root = doc ? yyjson_doc_get_root(doc) : NULL;
    const char *raw = NULL;
    if (yyjson_is_obj(root)) {
        yyjson_val *pv = yyjson_obj_get(root, "path");
        if (pv) raw = yyjson_get_str(pv);
    }
    if (!raw) { /* no path (or a non-string one): nothing to bind here — the
                * in-guest seat refuses the malformed call itself. */
        if (doc) yyjson_doc_free(doc);
        return 0;
    }
    char *apath;
#ifdef FH_MUTANT_OPS_NO_CANON
    /* P6 CANONICALIZATION BLIND (build/fx-hostgate-opsnocanon): match the RAW
     * path string against the pinned patterns.  Enables the host-seat SILENT
     * ALLOW this blind is the control for. */
    if (raw[0] != '/') {
        if (doc) yyjson_doc_free(doc);
        return 0;
    }
    apath = xstrdup(raw);
#else
    apath = fh_canon_abs(raw);
#endif
    if (!apath) { /* non-absolute or root-escaping: the in-guest seat refuses
                   * the same call (fx-verbs-server.c:1935-1958). */
        if (doc) yyjson_doc_free(doc);
        return 0;
    }
    if (doc) yyjson_doc_free(doc);

    uint32_t w = dl_intern_str(OPS.db, name);
    uint32_t p = dl_intern_str(OPS.db, apath);
    uint32_t tp[2] = { w, p };
    if (!w || !p || dl_add_fact(OPS.db, "touches", tp, 2) < 0) {
        free(apath);
        snprintf(why, whycap, "cannot inject the per-call facts (engine error) "
                              "— refusing, never allowing");
        return 1; /* FAIL-CLOSED: an unconsultable policy refuses */
    }
#ifdef FH_MUTANT_OPS_BIND_UNSEEN
    /* P6 D2-BOUND CONTROL (build/fx-hostgate-opsfloor): this seat binds a fact
     * it CANNOT see — the compiled-in floor.  D2 then fires (boot_verdict is
     * never injected), so this build denies a write the real build allows.
     * The gate's D2-bound arm is the asymmetry. */
    {
        uint32_t wf[1] = { p };
        if (dl_add_fact(OPS.db, "writable", wf, 1) < 0) {
            free(apath);
            snprintf(why, whycap, "cannot inject the FLOOR fact this build "
                                  "binds (bound-unseen control)");
            return 1;
        }
    }
#endif
    /* THE RESOLVE, per call: class(<path>, <class>) for every row whose
     * pattern hits the canonical path — the same loop the in-guest seat runs
     * at startup over its served set, here over the ONE path the call names. */
    for (size_t i = 0; i < OPS.n_row; i++) {
        if (!ops_pattern_hits(OPS.row[i].pattern, apath)) continue;
        uint32_t cf[2] = { p, dl_intern_str(OPS.db, OPS.row[i].class_sym) };
        if (!cf[1] || dl_add_fact(OPS.db, "class", cf, 2) < 0) {
            snprintf(why, whycap, "cannot inject the class fact for %s (the "
                                  "folding contract is machine-checked) — "
                                  "refusing, never allowing", apath);
            free(apath);
            return 1;
        }
    }

    size_t rows = 0;
    long qr = dl_query(OPS.db, "denied", ops_count_cb, &rows);
    if (qr < 0) {
        (void)dl_delete_fact(OPS.db, "touches", tp, 2);
        free(apath);
        snprintf(why, whycap, "dl_query(denied) failed — refusing, never "
                              "allowing");
        return 1;
    }

    /* PER-RULE ATTRIBUTION (denial path only; the C seat's own discipline —
     * fx-verbs-server.c:1496-1522): the derived relation is deduplicated with
     * no provenance, so each artifact rule is re-asked on a SHALLOW CLONE with
     * its HEAD RENAMED.  The rule text quoted in the denial is the artifact's
     * own. */
    int fired[32];
    size_t n_fired = 0;
    if (rows > 0) {
        for (size_t i = 0; i < OPS.n_rule && n_fired < 32; i++) {
            const char *rl = OPS.rule[i];
            if (strlen(rl) > 1024) continue;
            if (memcmp(rl, "denied(", 7) != 0) continue;
            char prog[1200], goal[32];
            snprintf(goal, sizeof goal, "ops_r%zu", i + 1);
            int sn = snprintf(prog, sizeof prog, "%s%s", goal, rl + 6);
            if (sn <= 0 || sn >= (int)sizeof prog) continue;
            size_t rn = 0;
            if (dl_query_rules_ro(OPS.db, prog, goal, ops_count_cb, &rn) >= 0
                && rn > 0)
                fired[n_fired++] = (int)i;
        }
    }

    int delbad = 0;
    if (dl_delete_fact(OPS.db, "touches", tp, 2) < 0) delbad = 1;
    /* THE CLASS FACTS TOO (P6-fix).  The per-call resolve loop above interns
     * and adds class(<canon path>,<class>) for every row whose pattern hits;
     * ONLY touches used to be retracted, so the EDB/WAL grew with every
     * DISTINCT classified path a stream named for the proxy's lifetime —
     * unbounded under a subtree row, where a caller can spray distinct
     * allowed children.  (Derived `denied` rows are deduplicated by the
     * engine and this seat re-adds what each call needs, so retracting here
     * cannot disturb another call — it is deterministic and per-call, exactly
     * like the add.)  Verdicts were already correct (touches is the per-call
     * discriminator); this is the record's growth, not a decision. */
    for (size_t i = 0; i < OPS.n_row; i++) {
        if (!ops_pattern_hits(OPS.row[i].pattern, apath)) continue;
        uint32_t cf[2] = { p, dl_intern_str(OPS.db, OPS.row[i].class_sym) };
        if (!cf[1] || dl_delete_fact(OPS.db, "class", cf, 2) < 0) delbad = 1;
    }
#ifdef FH_MUTANT_OPS_BIND_UNSEEN
    {
        uint32_t wf[1] = { p };
        if (dl_delete_fact(OPS.db, "writable", wf, 1) < 0) delbad = 1;
    }
#endif

    if (rows == 0) {
        free(apath);
        if (delbad) {
            snprintf(why, whycap, "cannot retract the per-call facts (they "
                                  "would latch onto the next call) — refusing, "
                                  "never allowing");
            return 1;
        }
        return 0;
    }

    /* THE DENIAL — the in-guest seat's shape, one line per FIRED rule, with
     * the rule number POSITIONAL over the artifact's own order (the compile is
     * deterministic) and the quoted rule text as the authority. */
    size_t off = 0;
    if (n_fired == 0)
        off += (size_t)snprintf(why + off, whycap - off,
                                "operator policy denies this write (no rule "
                                "attributed — the artifact and the engine "
                                "disagree; refusing, never allowing)");
    for (size_t i = 0; i < n_fired && off < whycap; i++) {
        int sn = snprintf(why + off, whycap - off,
                          "%soperator policy rule D%d: %s (verb %s, path %s)",
                          off ? "; " : "", fired[i] + 1, OPS.rule[fired[i]],
                          name, apath);
        if (sn <= 0) break;
        off += (size_t)sn;
    }
    if (delbad && off < whycap)
        snprintf(why + off, whycap - off, "; the per-call facts could not be "
                 "retracted (fail-closed: the next decision refuses until the "
                 "engine is clean)");
    free(apath);
    return 1;
}
#endif /* !FH_MUTANT_NO_OPS_SEAT */

/* ── P7: THE CLAIM AUTHOR at the HOST SEAT ─────────────────────────────── */
/*
 * The proxy gains the CLAIM author — the second of the design's two visibly
 * distinct authors (the operator says "you may not do this"; the claim author
 * says "this is not justified").  It REPLACES NOTHING: the P3 --deny denylist
 * and the P6 --ops-policy-dir operator seat stay exactly as they are.
 *
 * UNLIKE THE OPS SEAT (which links the datalog engine in-process), this seat
 * SHELLS policy/calls/eval_calls.py — a thin sibling of policy/eval_claim.py —
 * per call, EXACTLY as tools/fx-claim.c shells eval_claim.py (run_evaluator).
 * The reasoning is NEVER reimplemented in the proxy: the seat owns the RECORD
 * (temp files + the subprocess + the verdict parse), the evaluator owns the
 * free-LE compilation, the head check, the premise check and the `justified`
 * query.  `le` is consumed as a DEPENDENCY by the evaluator, never forked.
 *
 * THE SOUNDNESS BOUNDARY (the policy/calls header's argument, restated here
 * so the seat's own code names it): the agent gets free LE over a CLOSED,
 * host-declared lexicon (calls-lexicon.ini) that declares NO `justified` and
 * NO `denied`; the frozen policy (calls-policy.dl) is the ONLY concluder of
 * `justified`.  The seat injects the BINDING FACTS per call — call_name (the
 * runtime verb folded to its abstract symbol through the pinned calls-verbs.tsv),
 * call_purpose (the purpose the table assigns that verb) and forbidden_purpose
 * (the table's forbidden set, at startup) — so the agent's assertions are
 * never evidence and a spelled runtime symbol matches NOTHING (the letters-only
 * seam; see the calls-policy.le header).  Vacuity FALLS OUT: an argument that
 * never reaches the judgment rule derives zero rows and is `justified-not-
 * derived` — a refusal, not a police action.
 *
 * THE TWO-AUTHOR BOUNDARY, IN THE SEAT: the calls lexicon has no `denied`, the
 * ops lexicon has no `justified`, and this seat's judgment binds the call's
 * VERB and PURPOSE while the ops seat binds the PATH — two authors on two
 * DIFFERENT dimensions of the same call, and the verdict is DENY IF EITHER
 * REFUSES.
 *
 * ORDER IN call_judge: denylist -> ops -> justification (P5) -> claim.  The
 * claim author judges the JUSTIFICATION, so it runs only after P5 has
 * confirmed the justification is present and well-formed.  A denial takes the
 * SAME path as every other author (the true name never crosses; the denial
 * text reaches the model through the existing P3 outbound substitution),
 * with author="claim" and refusal_name="denied-by-claim"; the reason embeds
 * the evaluator's OWN refusal name (justified-not-derived / premise-false /
 * hostile-compile / ... — never paraphrased).
 *
 * THE PIN: every file policy/calls/PINS names must exist with the pinned
 * sha256, verified AT STARTUP before any verdict is believed (every file the
 * seat LOADS — calls-lexicon.ini, calls-policy.dl, calls-verbs.tsv AND the
 * eval_calls.py that computes the verdict — must be pinned at all; pinning
 * the artifacts while the evaluator that reads them is only stat()ed lets a
 * swapped always-`derives` evaluator cross a forbidden call silently).  An
 * ABSENT --calls-policy-dir is the NAMED "no claim author at this seat"
 * state, never an error.
 */
#define FH_CALLS_PINS      "PINS"
#define FH_CALLS_LEX       "calls-lexicon.ini"
#define FH_CALLS_DL        "calls-policy.dl"
#define FH_CALLS_VERBS     "calls-verbs.tsv"
#define FH_CALLS_EVAL      "eval_calls.py"
#define FH_CALLS_MAX_FILE  (1024u * 1024u)
/* The fixed abstract identity the seat binds every call to: the agent cannot
 * know the runtime call_id (it writes the justification in the SAME turn,
 * before the id exists), so the seat maps every call to the ONE abstract
 * symbol the agent's vocabulary declares (CallA -> calla). */
#define FH_CALLS_CALL_SYM  "calla"

typedef struct {
    char *verb;         /* the RUNTIME verb name (never a proper noun) */
    char *verb_sym;     /* FOLDED abstract verb symbol (le's fold) */
    char *purpose_sym;  /* FOLDED purpose symbol */
    int   forb;         /* the forbidden-purpose flag (the guard's fact) */
} FhCallsRow;

static struct {
    int loaded;    /* a policy dir was given AND every startup check passed */
    int present;   /* ...AND the seat can actually judge (loaded) */
    char dir[PATH_MAX];
    char evalpy[PATH_MAX];
    char lex_path[PATH_MAX];
    char dl_path[PATH_MAX];
    char pins_path[PATH_MAX];
    char dl_sha[65];
    FhCallsRow *row;
    size_t n_row;
} CALLS;

/* "Did an author that CAN REFUSE actually run here?" — the honesty rule's
 * question (policy_armed, authors_ran).  Compiled out entirely in the
 * pre-fix control. */
static int calls_seat_present(void) {
#ifdef FH_MUTANT_NO_CLAIM_SEAT
    return 0;
#else
    return CALLS.present;
#endif
}

#ifndef FH_MUTANT_NO_CLAIM_SEAT

/* single-quote a path for the command line (the fx-claim.c sh_quote shape); a
 * path carrying a single quote is refused before it ever reaches here. */
static char *fh_sh_quote(const char *s) {
    size_t n = strlen(s) + 4;
    char *out = xmalloc(n);
    snprintf(out, n, "'%s'", s);
    return out;
}

static void calls_gate_die(const char *fmt, ...) {
    fputs("fx-hostgate: calls-policy REFUSED: ", stderr);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    exit(1);
}

static char *calls_read_file(const char *path, size_t *len_out) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    size_t cap = 8192, len = 0;
    char *buf = malloc(cap + 1);
    if (!buf) { fclose(f); return NULL; }
    for (;;) {
        if (len == cap) {
            if (cap >= FH_CALLS_MAX_FILE) {
                errno = EFBIG;
                free(buf); fclose(f); return NULL;
            }
            cap *= 2;
            char *nb = realloc(buf, cap + 1);
            if (!nb) { free(buf); fclose(f); return NULL; }
            buf = nb;
        }
        size_t n = fread(buf + len, 1, cap - len, f);
        len += n;
        if (n == 0) break;
    }
    if (ferror(f)) { free(buf); fclose(f); return NULL; }
    fclose(f);
    buf[len] = '\0';
    if (len_out) *len_out = len;
    return buf;
}

/* THE PIN CHECK: every file PINS names must exist with the pinned sha256;
 * every file the seat LOADS — the three policy artifacts AND the EVALUATOR
 * that computes the verdict — must be pinned at all.  Names BOTH shas on a
 * mismatch. */
static void calls_verify_pins(const char *dir, const char *pins_path) {
    size_t plen = 0;
    char *pins = calls_read_file(pins_path, &plen);
    if (!pins)
        calls_gate_die("%s cannot be read: %s — a present policy dir must "
                       "carry a verifiable pin set", pins_path, strerror(errno));
    int saw_lex = 0, saw_dl = 0, saw_verbs = 0, saw_eval = 0;
    char *save = NULL;
    for (char *line = strtok_r(pins, "\n", &save); line;
         line = strtok_r(NULL, "\n", &save)) {
        while (*line == ' ' || *line == '\t') line++;
        if (!*line || *line == '#') continue;
        char *tab = strchr(line, '\t');
        if (!tab)
            calls_gate_die("%s: a pin row is name<TAB>sha256, got '%.80s'",
                           pins_path, line);
        *tab = '\0';
        char *name = line, *want = tab + 1;
        char *cr = strchr(want, '\r');
        if (cr) *cr = '\0';
        int is_lex = strcmp(name, FH_CALLS_LEX) == 0;
        int is_dl = strcmp(name, FH_CALLS_DL) == 0;
        int is_verbs = strcmp(name, FH_CALLS_VERBS) == 0;
        int is_eval = strcmp(name, FH_CALLS_EVAL) == 0;
        if (is_lex) saw_lex = 1;
        if (is_dl) saw_dl = 1;
        if (is_verbs) saw_verbs = 1;
        if (is_eval) saw_eval = 1;
#ifdef FH_MUTANT_NO_EVAL_PIN
        /* PRE-FIX CONTROL (build/fx-hostgate-noevalpin): the evaluator that
         * COMPUTES every verdict is EXEMPT from the pin check (only stat()ed
         * below), exactly the P7 pre-fix behavior — a swapped always-derives
         * evaluator arms happily and a forbidden call crosses and EXECUTES. */
        if (is_eval) continue;
#endif
        char path[PATH_MAX];
        int n = snprintf(path, sizeof path, "%s/%s", dir, name);
        if (n <= 0 || n >= (int)sizeof path)
            calls_gate_die("pin path too long: %s", name);
        size_t flen = 0;
        char *bytes = calls_read_file(path, &flen);
        if (!bytes)
            calls_gate_die("pinned file %s is MISSING or unreadable (: %s) "
                           "(pinned sha256 %s) — restore it or re-pin",
                           path, strerror(errno), want);
        char got[65];
        sha256_hex(bytes, flen, got);
        if (strcmp(got, want) != 0) {
            free(bytes);
            calls_gate_die("pinned file %s sha256 mismatch: pinned %s != actual "
                           "%s — the deployed artifact is stale or swapped; a "
                           "policy edit is a re-pin (artifact + PINS in the "
                           "same release)", path, want, got);
        }
        if (is_dl)
            snprintf(CALLS.dl_sha, sizeof CALLS.dl_sha, "%s", want);
        free(bytes);
    }
    free(pins);
    if (!saw_lex || !saw_dl || !saw_verbs || !saw_eval)
        calls_gate_die("%s does not pin all of %s, %s, %s and %s — the loaded "
                       "artifacts AND the evaluator that computes the verdict "
                       "would go unverified", pins_path, FH_CALLS_LEX,
                       FH_CALLS_DL, FH_CALLS_VERBS, FH_CALLS_EVAL);
}

/* THE FOLD (the folding contract's seat half): le compiles a proper noun to
 * its LOWERCASED dl symbol, so the seat folds the table's surfaces before
 * writing them — an unfolded surface could only ever non-match a legal rule's
 * folded constant (a policy that stops matching stops protecting, silently). */
static int calls_fold_proper(char *dst, size_t dstsz, const char *src) {
    size_t l = strlen(src);
    if (l == 0 || l >= dstsz) return 0;
    for (size_t i = 0; i < l; i++) {
        unsigned char c = (unsigned char)src[i];
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z'))) return 0;
        dst[i] = (char)(c | 0x20);
    }
    dst[l] = '\0';
    return 1;
}

/* The verb table: verb<TAB>verb-symbol<TAB>purpose<TAB>forbidden.  The
 * verb-symbol and purpose surfaces must be proper nouns (letters-only) —
 * a runtime verb spelled as an underscored proper noun could never reach a
 * rule.  Duplicate runtime verbs are refused. */
static void calls_load_verbs(const char *path, char *tsv_owned) {
    char *tsv = tsv_owned;
    size_t cap = 8;
    CALLS.row = xmalloc(cap * sizeof *CALLS.row);
    char *save = NULL;
    for (char *line = strtok_r(tsv, "\n", &save); line;
         line = strtok_r(NULL, "\n", &save)) {
        while (*line == ' ' || *line == '\t') line++;
        size_t ll = strlen(line);
        if (ll > 0 && line[ll - 1] == '\r') line[ll - 1] = '\0';
        if (!*line || *line == '#') continue;
        char *f[4];
        int nf = 0;
        char *lsave = NULL;
        for (char *tok = strtok_r(line, "\t", &lsave); tok && nf < 4;
             tok = strtok_r(NULL, "\t", &lsave))
            f[nf++] = tok;
        if (nf != 4)
            calls_gate_die("%s: a verb row is verb<TAB>verb-symbol<TAB>purpose"
                           "<TAB>forbidden, got %d field(s)", path, nf);
        if (strcmp(f[3], "yes") != 0 && strcmp(f[3], "no") != 0)
            calls_gate_die("%s: the forbidden flag is '%s', not yes|no", path, f[3]);
        for (size_t i = 0; i < CALLS.n_row; i++)
            if (strcmp(CALLS.row[i].verb, f[0]) == 0)
                calls_gate_die("%s: the runtime verb '%s' is mapped twice",
                               path, f[0]);
        if (CALLS.n_row == cap) {
            cap *= 2;
            CALLS.row = realloc(CALLS.row, cap * sizeof *CALLS.row);
            if (!CALLS.row) die_errno("realloc calls verb rows");
        }
        FhCallsRow *r = &CALLS.row[CALLS.n_row];
        memset(r, 0, sizeof *r);
        r->verb = xstrdup(f[0]);
        r->verb_sym = xmalloc(strlen(f[1]) + 1);
        r->purpose_sym = xmalloc(strlen(f[2]) + 1);
        if (!calls_fold_proper(r->verb_sym, strlen(f[1]) + 1, f[1]))
            calls_gate_die("%s: the verb-symbol '%s' is not a proper noun "
                           "(ASCII letters only) — le compiles proper nouns to "
                           "their lowercased symbol, so any other shape could "
                           "only ever match nothing", path, f[1]);
        /* THE SHARE FORM: the duplicate-runtime-verb check above catches one
         * verb mapped twice, but NOT two verbs sharing one folded SYMBOL
         * (the table's spine is per-symbol, so one contention for a shared
         * symbol would justify both runtime verbs and the claim rule's
         * demand — "contends for the verb the call really is" — would stop
         * discriminating).  Refused here as loudly as in --check-verbs. */
        for (size_t i = 0; i < CALLS.n_row; i++)
            if (strcmp(CALLS.row[i].verb_sym, r->verb_sym) == 0)
                calls_gate_die("%s: the verb-symbol '%s' (folded '%s') is "
                               "mapped by BOTH '%s' and '%s' — one contention "
                               "would justify both runtime verbs", path, f[1],
                               r->verb_sym, CALLS.row[i].verb, f[0]);
        if (!calls_fold_proper(r->purpose_sym, strlen(f[2]) + 1, f[2]))
            calls_gate_die("%s: the purpose '%s' is not a proper noun (ASCII "
                           "letters only)", path, f[2]);
        r->forb = (strcmp(f[3], "yes") == 0);
        CALLS.n_row++;
    }
    free(tsv);
    if (CALLS.n_row == 0)
        calls_gate_die("%s carries no verb rows — the vocabulary seam's binding "
                       "table is empty and every verb would be unjudgeable", path);
}

/* The real startup. */
static void calls_seat_load(const char *dir) {
    struct stat st;
    /* The dir path rides a shell command line (the evaluator invocation), so a
     * quote or control character is refused here — the fx-claim.c
     * check_safe_path discipline.  Model-controlled bytes (the justification)
     * never reach the command line: they ride mkstemp files whose paths are
     * generated, not quoted. */
    for (const char *c = dir; *c; c++)
        if ((unsigned char)*c < 0x20 || *c == '\'')
            calls_gate_die("the --calls-policy-dir path carries a character "
                           "this seat refuses to put on a command line");
    if (stat(dir, &st) != 0 || !S_ISDIR(st.st_mode))
        calls_gate_die("%s is not a readable directory — a --calls-policy-dir "
                       "must name the directory holding %s, %s, %s and %s",
                       dir, FH_CALLS_PINS, FH_CALLS_LEX, FH_CALLS_DL,
                       FH_CALLS_VERBS);
    /* TMPDIR carries the same hazard as the policy dir: the mkstemp paths
     * under it ride the evaluator's command line (single-quoted by
     * calls_run_evaluator), so a quote or control character cannot be
     * shell-quoted safely.  Checked at LOAD, not per call, for the reason the
     * policy dir is: a malformed operator env has no later moment at which
     * the refusal could be early enough to be a gate.  Operator env only —
     * model bytes never reach the command line (every path is generated by
     * mkstemp, never echoed from model text). */
    {
        const char *tmp = getenv("TMPDIR");
        if (!tmp || !*tmp) tmp = "/tmp";
        for (const char *c = tmp; *c; c++)
            if ((unsigned char)*c < 0x20 || *c == '\'')
                calls_gate_die("TMPDIR ('%s') carries a character this seat "
                               "refuses to put on a command line (a quote or "
                               "control character cannot be shell-quoted "
                               "safely)", tmp);
    }
    snprintf(CALLS.dir, sizeof CALLS.dir, "%s", dir);
    snprintf(CALLS.pins_path, sizeof CALLS.pins_path, "%s/%s", dir, FH_CALLS_PINS);
    snprintf(CALLS.lex_path, sizeof CALLS.lex_path, "%s/%s", dir, FH_CALLS_LEX);
    snprintf(CALLS.dl_path, sizeof CALLS.dl_path, "%s/%s", dir, FH_CALLS_DL);
    snprintf(CALLS.evalpy, sizeof CALLS.evalpy, "%s/%s", dir, FH_CALLS_EVAL);
    calls_verify_pins(dir, CALLS.pins_path);

    char verbs_path[PATH_MAX];
    snprintf(verbs_path, sizeof verbs_path, "%s/%s", dir, FH_CALLS_VERBS);
    char *verbs_bytes = calls_read_file(verbs_path, NULL);
    if (!verbs_bytes)
        calls_gate_die("%s cannot be read: %s", verbs_path, strerror(errno));
    calls_load_verbs(verbs_path, verbs_bytes);

    if (stat(CALLS.evalpy, &st) != 0 || !S_ISREG(st.st_mode))
        calls_gate_die("%s is missing — the seat shells the evaluator, it never "
                       "reimplements the reasoning", CALLS.evalpy);

    CALLS.loaded = 1;
    CALLS.present = 1; /* a loaded calls seat can always refuse */
}

static void calls_seat_startup(const char *dir) {
    memset(&CALLS, 0, sizeof CALLS);
    if (!dir) {
        note("calls-policy: NONE — no --calls-policy-dir was given, so the "
             "claim author does not act at this seat (the justification, if "
             "required, is still checked by P5; this is a per-seat state, not "
             "an error)");
        return;
    }
    calls_seat_load(dir);
    note("calls-policy: seat ARMED — %zu verb row(s) loaded from the pinned "
         "table (artifact sha256 %.16s..); the claim author judges every "
         "call's justification against policy/calls (free LE over the closed "
         "agent lexicon, no 'justified', no 'denied'); a justified call is "
         "allowed, a not-justified call is DENIED BY NAME (denied-by-claim)",
         CALLS.n_row, CALLS.dl_sha);
}

#else /* FH_MUTANT_NO_CLAIM_SEAT */

/* P7 PRE-FIX CONTROL (build/fx-hostgate-noclaim): the claim seat is compiled
 * OUT while --calls-policy-dir is still ACCEPTED and IGNORED, so the build
 * runs exactly the P6-era proxy.  DIRECTION: FAIL-OPEN — a call the pinned
 * policy refuses (a forbidden purpose) crosses verbatim and EXECUTES. */
static void calls_seat_startup(const char *dir) {
    memset(&CALLS, 0, sizeof CALLS);
    if (dir)
        note("calls-policy: SEAT COMPILED OUT (FH_MUTANT_NO_CLAIM_SEAT) — the "
             "policy dir %s is ACCEPTED AND IGNORED: this is the PRE-FIX "
             "control, the claim author does NOT run, and a call the pinned "
             "policy refuses will CROSS and EXECUTE", dir);
    else
        note("calls-policy: SEAT COMPILED OUT (FH_MUTANT_NO_CLAIM_SEAT)");
}

#endif /* FH_MUTANT_NO_CLAIM_SEAT */

/* Run policy/calls/eval_calls.py once for this call; return the exit code and
 * the captured stdout (the VERDICT record, verbatim).  The evaluator's stderr
 * is left on the seat's stderr: a tool error names itself there.
 *
 * THE BOUND: the subprocess is run under a DEADLINE and reaped with SIGKILL
 * if it overruns (rc -2), because the alternative is an UNBOUNDED whole-seat
 * stall in which the guest's turn ends, the call is never judged, and NO log
 * row is written (rows are appended only after calls_judge returns) — so the
 * denial-rate instrument meant to detect exactly this is blind to it.  The
 * refusal still happens (fail-closed) but now on a deadline, and the row
 * makes the call visible.  A bound is not a policy: it is the seat refusing
 * to be hung by the thing it shells. */
#ifndef FH_MUTANT_NO_CLAIM_SEAT
#define FH_CALLS_EVAL_TIMEOUT_SEC 20
#define FX_HOSTGATE_EVAL_TIMEOUT_ENV "FX_HOSTGATE_EVAL_TIMEOUT"

/* The per-call bound, read from OPERATOR ENV ONLY (never model bytes) and
 * validated to [1, 3600] so it can never be set to "no timeout"; the gate
 * leans on it to exercise the path without a minute-long sleep. */
static int calls_eval_timeout_sec(void) {
    const char *e = getenv(FX_HOSTGATE_EVAL_TIMEOUT_ENV);
    if (!e || !*e) return FH_CALLS_EVAL_TIMEOUT_SEC;
    char *end = NULL;
    long v = strtol(e, &end, 10);
    if (!end || *end || v < 1 || v > 3600)
        calls_gate_die("%s=%s is not an integer in [1, 3600] — the per-call "
                       "evaluator bound must be a positive number of seconds",
                       FX_HOSTGATE_EVAL_TIMEOUT_ENV, e);
    return (int)v;
}

static int calls_run_evaluator(const char *call_path, const char *le_path,
                               const char *facts_path, char **out) {
    char *qe = fh_sh_quote(CALLS.evalpy);
    char *qc = fh_sh_quote(call_path);
    char *ql = fh_sh_quote(le_path);
    char *qlex = fh_sh_quote(CALLS.lex_path);
    char *qpol = fh_sh_quote(CALLS.dl_path);
    char *qf = fh_sh_quote(facts_path);
    char *qpin = fh_sh_quote(CALLS.pins_path);
    char *cmd;
    if (asprintf(&cmd,
                 "python3 %s --call %s --le %s --lexicon %s --policy %s "
                 "--facts %s --pins %s",
                 qe, qc, ql, qlex, qpol, qf, qpin) < 0)
        die_errno("out of memory");
    free(qe); free(qc); free(ql); free(qlex); free(qpol); free(qf); free(qpin);

    int fds[2];
    if (pipe(fds) != 0)
        calls_gate_die("cannot create the evaluator pipe (%s)", strerror(errno));
    pid_t pid = fork();
    if (pid < 0)
        calls_gate_die("cannot fork the evaluator (%s)", strerror(errno));
    if (pid == 0) {
        /* the child: exec through the shell exactly as popen did.  A failure
         * here is 127, which the parent reads as a tool error (fail-closed). */
        close(fds[0]);
        if (dup2(fds[1], STDOUT_FILENO) < 0) _exit(127);
        close(fds[1]);
        execl("/bin/sh", "sh", "-c", cmd, (char *)NULL);
        _exit(127);
    }
    close(fds[1]);
    int fl = fcntl(fds[0], F_GETFL, 0);
    if (fl < 0 || fcntl(fds[0], F_SETFL, fl | O_NONBLOCK) < 0)
        calls_gate_die("cannot set the evaluator pipe non-blocking (%s)",
                       strerror(errno));

    int bound = calls_eval_timeout_sec();
    struct timespec start;
    clock_gettime(CLOCK_MONOTONIC, &start);
    size_t cap = 16384, len = 0;
    char *buf = xmalloc(cap);
    int timedout = 0;
    for (;;) {
        if (len + 4096 > cap - 1) { cap *= 2; buf = realloc(buf, cap); }
        ssize_t n = read(fds[0], buf + len, cap - len - 1);
        if (n > 0) { len += (size_t)n; continue; }
        if (n == 0) break; /* EOF: the child closed stdout -> reap below */
        if (errno == EINTR) continue;
        if (errno != EAGAIN && errno != EWOULDBLOCK) break; /* real error */
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        double elapsed = (double)(now.tv_sec - start.tv_sec)
                       + (double)(now.tv_nsec - start.tv_nsec) / 1e9;
        struct timeval tv;
        struct timeval *tvp = &tv;
#ifndef FH_MUTANT_NO_EVAL_BOUND
        if (elapsed >= (double)bound) { timedout = 1; break; }
        double remain = (double)bound - elapsed;
        tv.tv_sec = (time_t)remain;
        tv.tv_usec = (suseconds_t)((remain - (double)tv.tv_sec) * 1e6);
#else
        /* PRE-FIX CONTROL (build/fx-hostgate-nobound): NO deadline — the seat
         * blocks on the evaluator forever, the guest's turn ends with the call
         * never judged, and NO row is written (rows are appended only after
         * calls_judge returns), so the dead-agent instrument is blind to it. */
        tvp = NULL;
        (void)start; (void)bound; (void)elapsed;
#endif
        fd_set rf;
        FD_ZERO(&rf);
        FD_SET(fds[0], &rf);
        select(fds[0] + 1, &rf, NULL, NULL, tvp);
    }
    free(cmd);
    int st = 0, rc;
    if (timedout) {
        kill(pid, SIGKILL);
        waitpid(pid, &st, 0);
        rc = -2;
    } else {
        waitpid(pid, &st, 0);
        rc = WIFEXITED(st) ? WEXITSTATUS(st) : -1;
    }
    close(fds[0]);
    buf[len] = '\0';
    *out = buf;
    return rc;
}

/* write a mkstemp file holding `data`, return the path (malloc'd). */
static char *calls_write_temp(const char *tag, const char *data, size_t len) {
    const char *tmp = getenv("TMPDIR");
    if (!tmp || !*tmp) tmp = "/tmp";
    char tmpl[PATH_MAX];
    int n = snprintf(tmpl, sizeof tmpl, "%s/fx-hostgate-calls-%s-XXXXXX", tmp, tag);
    if (n <= 0 || n >= (int)sizeof tmpl)
        calls_gate_die("cannot build the temp path under %s", tmp);
    int fd = mkstemp(tmpl);
    if (fd < 0) calls_gate_die("cannot create the temp file: %s", strerror(errno));
    if (write_all(fd, (const unsigned char *)data, len) != 0)
        calls_gate_die("cannot write the temp file: %s", strerror(errno));
    if (close(fd) != 0) calls_gate_die("cannot close the temp file: %s", strerror(errno));
    return xstrdup(tmpl);
}

/* The justification string from the call's arguments (the same extraction the
 * P5 judge uses).  Returns NULL when absent/non-string/blank. */
static char *calls_extract_justification(const char *args) {
    if (!args || !*args) return NULL;
    yyjson_doc *doc = yyjson_read(args, strlen(args), 0);
    yyjson_val *root = doc ? yyjson_doc_get_root(doc) : NULL;
    char *out = NULL;
    if (yyjson_is_obj(root)) {
        yyjson_val *jv = yyjson_obj_get(root, "justification");
        const char *js = jv ? yyjson_get_str(jv) : NULL;
        if (js) {
            int blank = 1;
            for (const char *p = js; *p; p++)
                if (!isspace((unsigned char)*p)) { blank = 0; break; }
            if (!blank) out = xstrdup(js);
        }
    }
    if (doc) yyjson_doc_free(doc);
    return out;
}

/* THE PER-CALL DECISION.  Returns 1 when this seat DENIES (filling `why`),
 * 0 when it does not refuse (the justification derives).  Injects the binding
 * facts, shells the evaluator, parses its verdict.  A tool error (exit 2, or
 * an unparsable verdict) is FAIL-CLOSED: refuse, never allow. */
static int calls_judge(const char *name, const char *args, char *why, size_t whycap) {
    if (!CALLS.present) return 0;

    /* THE VERB — look it up in the pinned table.  A verb the table cannot bind
     * has no declared purpose, so its justification cannot be judged here:
     * fail-closed (refuse, never allow). */
    FhCallsRow *row = NULL;
    for (size_t i = 0; i < CALLS.n_row; i++)
        if (strcmp(CALLS.row[i].verb, name) == 0) { row = &CALLS.row[i]; break; }
    if (!row) {
        snprintf(why, whycap,
                 "the call's verb \"%s\" has no row in the pinned calls-verbs "
                 "table — the claim author cannot judge it justified (a verb "
                 "the table cannot bind is refused, never silently allowed)",
                 name);
        return 1;
    }

    char *just = calls_extract_justification(args);
    if (!just) {
        snprintf(why, whycap,
                 "the call carries no justification to judge (the claim author "
                 "judges the justification; an absent one is refused, never "
                 "silently allowed)");
        return 1;
    }

    /* the binding facts: call row + seat facts (call_purpose + forbidden). */
    char call_row[PATH_MAX];
    snprintf(call_row, sizeof call_row, "%s\t%s\n", FH_CALLS_CALL_SYM, row->verb_sym);
    size_t fcap = 8192, flen = 0;
    char *facts = xmalloc(fcap);
    int sn = snprintf(facts + flen, fcap - flen, "call_purpose\t%s\t%s\n",
                      FH_CALLS_CALL_SYM, row->purpose_sym);
    flen += (size_t)sn;
    for (size_t i = 0; i < CALLS.n_row; i++) {
        if (!CALLS.row[i].forb) continue;
        if (flen + 256 >= fcap) { fcap *= 2; facts = realloc(facts, fcap); }
        sn = snprintf(facts + flen, fcap - flen, "forbidden_purpose\t%s\n",
                      CALLS.row[i].purpose_sym);
        flen += (size_t)sn;
    }

    char *call_path = calls_write_temp("call", call_row, strlen(call_row));
    char *le_path = calls_write_temp("le", just, strlen(just));
    char *facts_path = calls_write_temp("facts", facts, flen);
    free(just);
    free(facts);

    char *out = NULL;
    int rc = calls_run_evaluator(call_path, le_path, facts_path, &out);

    /* parse the evaluator's verdict line: exit 0 -> derives; exit 1 -> a named
     * refusal; anything else -> tool error (fail-closed). */
    const char *verdict = NULL;
    for (const char *p = out; p && *p;) {
        const char *eol = strchr(p, '\n');
        size_t ll = eol ? (size_t)(eol - p) : strlen(p);
        if (ll >= 8 && !strncmp(p, "verdict\t", 8)) verdict = p;
        p = eol ? eol + 1 : p + ll;
    }
    int deny = 0;
    if (rc == 0) {
        if (!verdict || strncmp(verdict, "verdict\tderives", 15)) {
            snprintf(why, whycap,
                     "the evaluator exited 0 but its stdout carries no "
                     "'verdict<TAB>derives' line — an unparsable verdict is a "
                     "tool error, never a silent derives; refusing");
            deny = 1;
        }
    } else if (rc == 1) {
        if (!verdict || strncmp(verdict, "verdict\trefused\t", 16)) {
            snprintf(why, whycap,
                     "the evaluator refused (exit 1) but its stdout carries no "
                     "'verdict<TAB>refused<TAB>name' line — an unnamed refusal "
                     "is a tool error; refusing");
        } else {
            const char *nm = verdict + 16;
            const char *eol = strchr(nm, '\n');
            size_t ll = eol ? (size_t)(eol - nm) : strlen(nm);
            snprintf(why, whycap, "the justification does not derive (%.*s)",
                     (int)ll, nm);
        }
        deny = 1;
    } else if (rc == -2) {
        snprintf(why, whycap,
                 "the evaluator did not finish within the seat's timeout (%d "
                 "s) — a hung evaluator is a tool error, not a verdict; "
                 "refusing (fail-closed, never allowing)",
                 calls_eval_timeout_sec());
        deny = 1;
    } else {
        snprintf(why, whycap,
                 "the evaluator exited %d — a tool error is infrastructure, "
                 "not a verdict; refusing (fail-closed, never allowing)", rc);
        deny = 1;
    }

    free(out);
    unlink(call_path);
    unlink(le_path);
    unlink(facts_path);
    free(call_path);
    free(le_path);
    free(facts_path);
    return deny;
}
#endif /* !FH_MUTANT_NO_CLAIM_SEAT */


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
#ifndef FH_MUTANT_NO_OPS_SEAT
    /* P6 — THE OPERATOR AUTHOR at this seat.  The rule vocabulary is the
     * pinned ops policy's; the facts are the ones this seat can DERIVE (see
     * the P6 header block: D1-class only, D2 is inert here and lives
     * in-guest).  A denial takes the SAME path as the others: the true name
     * never crosses, and this reason is what the model reads. */
    {
        char why[700];
        if (ops_judge(name, args, why, sizeof why)) {
            snprintf(reason, reason_cap, "\"%s\" was DENIED BY OPS: %s",
                     name, why);
            *author_out = FH_AUTHOR_OPS;
            *refusal_out = FH_REFUSAL_OPS;
            return 1;
        }
    }
#endif /* FH_MUTANT_NO_OPS_SEAT */
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
#ifndef FH_MUTANT_NO_CLAIM_SEAT
    /* P7 — THE CLAIM AUTHOR at this seat.  Runs LAST (after the justification
     * check), because the claim author judges the justification: a denial
     * takes the SAME path as the others (the true name never crosses, and
     * this reason is what the model reads).  calls_judge extracts the
     * justification itself and fails closed on an unmapped verb or an absent
     * justification. */
    {
        char why[700];
        if (calls_judge(name, args, why, sizeof why)) {
            snprintf(reason, reason_cap, "\"%s\" was DENIED BY CLAIM: %s",
                     name, why);
            *author_out = FH_AUTHOR_CLAIM;
            *refusal_out = FH_REFUSAL_CLAIM;
            return 1;
        }
    }
#endif /* FH_MUTANT_NO_CLAIM_SEAT */
    return 0;
}

#endif /* FH_MUTANT_SINGLE_ITEM */

/* The AUTHOR field on an ALLOWED row: the authors ARMED AND CONSULTED at this
 * seat, joined.  A row claiming an author that did not run would be a record
 * wider than the evidence (the same rule that keeps P2 rows verdict-free) —
 * and, the other way, "armed" is not "evaluated THIS call": the ops judge
 * returns before the pinned policy is consulted for a verb it does not
 * classify as a write, so an allowed non-write row's `ops` names an author
 * that was present, not one that judged the call.  The row's allow_scope
 * carries the reading; the field itself is the seat's author set. */
static const char *authors_ran(void) {
    int o = ops_seat_present();
    int c = calls_seat_present();
    if (g_ndeny > 0 && o && c && g_require_justify) return "denylist+ops+claim+justification";
    if (g_ndeny > 0 && o && c) return "denylist+ops+claim";
    if (g_ndeny > 0 && o && g_require_justify) return "denylist+ops+justification";
    if (g_ndeny > 0 && o) return "denylist+ops";
    if (g_ndeny > 0 && c && g_require_justify) return "denylist+claim+justification";
    if (g_ndeny > 0 && c) return "denylist+claim";
    if (o && c && g_require_justify) return "ops+claim+justification";
    if (o && c) return "ops+claim";
    if (o && g_require_justify) return "ops+justification";
    if (c && g_require_justify) return "claim+justification";
    if (g_ndeny > 0 && g_require_justify) return "denylist+justification";
    if (g_ndeny > 0) return FH_AUTHOR_DENYLIST;
    if (o) return FH_AUTHOR_OPS;
    if (c) return FH_AUTHOR_CLAIM;
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
    note("usage: %s --upstream FILE --slave-file PATHFILE --log LOGFILE [--turns N] [--deny NAME]... [--require-justification] [--ops-policy-dir DIR] [--dump-requests PATH]",
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
    note("  --ops-policy-dir DIR  arm P6: THE OPERATOR AUTHOR at this seat.");
    note("                  DIR holds the PINNED ops policy (PINS +");
    note("                  ops-policy.dl + ops-aliases.tsv, e.g. policy/ops).");
    note("                  Verified against PINS at startup; its D1-class");
    note("                  rules are evaluated per write call and a denial");
    note("                  takes the normal deny path (author `ops`).  The");
    note("                  D2-class rules and the compiled-in floor stay");
    note("                  IN-GUEST — the startup line says exactly which");
    note("                  rules are live here");
    note("  --calls-policy-dir DIR  arm P7: THE CLAIM AUTHOR at this seat.");
    note("                  DIR holds the PINNED calls policy (PINS +");
    note("                  calls-lexicon.ini + calls-policy.dl +");
    note("                  calls-verbs.tsv + eval_calls.py, e.g. policy/calls).");
    note("                  Verified against PINS at startup; every call's");
    note("                  justification is judged by shelling eval_calls.py");
    note("                  (free LE over the closed agent lexicon) and a");
    note("                  not-justified call is denied (author `claim`,");
    note("                  refusal denied-by-claim)");
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
        } else if (!strcmp(argv[i], "--ops-policy-dir") && i + 1 < argc) {
            g_ops_dir = argv[++i];
        } else if (!strcmp(argv[i], "--calls-policy-dir") && i + 1 < argc) {
            g_calls_dir = argv[++i];
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

    /* P6 — THE OPERATOR AUTHOR.  Loaded (and refused, loudly) AFTER the name
     * contract and still BEFORE the slave path is published: a policy that
     * fails its pin or its alias grammar has no later moment at which the
     * refusal could be early enough to be a gate. */
    ops_seat_startup(g_ops_dir);

    /* P7 — THE CLAIM AUTHOR.  Loaded (and refused, loudly) AFTER the operator
     * seat and still BEFORE the slave path is published, for the same reason:
     * a policy that fails its pin or its verb table has no later moment at
     * which the refusal could be early enough to be a gate. */
    calls_seat_startup(g_calls_dir);

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
     * placeholder author; the ops policy at THIS seat, the claim policy at
     * this seat and the justification check are real; the reserved name is
     * refused by the verbs server even in an allow-all lane (structural
     * backstop, P3) AND checked against the pinned catalog at startup (P4). */
    if (policy_armed()) {
        note("policy: authors armed = %s; reserved name=%s (P4 contract checked "
             "at startup)",
             authors_ran(), FH_RESERVED_NAME);
        for (size_t d = 0; d < g_ndeny; d++) {
            note("policy: PLACEHOLDER denylist entry \"%s\"", g_deny_list[d]);
        }
        if (ops_seat_present()) {
            note("policy: THE OPERATOR AUTHOR IS LIVE at this seat "
                 "(--ops-policy-dir %s): its D1-class rules are evaluated per "
                 "write call against the pinned alias table.  D2-class rules "
                 "and the compiled-in floor remain IN-GUEST (the startup block "
                 "above names exactly which rules are live here)",
                 OPS.dir);
        }
        if (calls_seat_present()) {
            note("policy: THE CLAIM AUTHOR IS LIVE at this seat "
                 "(--calls-policy-dir %s): every call's justification is judged "
                 "against policy/calls (free LE over the closed agent lexicon) "
                 "by shelling eval_calls.py — a justified call is allowed, a "
                 "not-justified call is DENIED BY NAME (denied-by-claim)",
                 CALLS.dir);
            if (!g_require_justify)
                note("policy: NOTE — the claim author is armed WITHOUT "
                     "--require-justification: the model is never told to "
                     "justify (no tool-catalog injection), so an absent "
                     "justification is DENIED BY NAME (denied-by-claim, "
                     "'carries no justification') for EVERY call — expect "
                     "denial_rate 1.0000 and no call executing; add "
                     "--require-justification if that is not what you meant");
        }
        if (g_require_justify) {
            note("policy: JUSTIFICATION REQUIRED for every call (P5) — the tool "
                 "catalog is injected into the forwarded request and an "
                 "absent/malformed justification is DENIED BY NAME "
                 "(absent-justification / malformed-justification)");
        }
    } else {
        note("policy: NONE — no denylist given, no --require-justification, no "
             "live --ops-policy-dir and no live --calls-policy-dir, so no "
             "verdict fields are rendered; every call is recorded and "
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
