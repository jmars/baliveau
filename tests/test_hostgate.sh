#!/usr/bin/env bash
# tests/test_hostgate.sh — THE HOST PROXY'S GATE (slices P1 transparency +
# P2 the one log and the request<->response<->next-request join).
#
# P1 DIRECTION (stated up front): a transparency mistake is LOUD.  The
# assertion is EXACT marker equality of the guest harness's stdout; any
# mangling of the stream the guest reads flips it to a mismatch, and the
# mutation arm below proves the flip on exactly this fixture — so a clean
# pass cannot be vacuous.
#
# P2 DIRECTION: a MISSED JOIN is a SILENT DEGRADATION — the record looks
# complete but is not (the plan's second failure direction, obs 5).  The
# exit status cannot see it: a proxy whose join never fires still runs the
# guest to a clean rc 0.  So the P2 phases assert the LOG BY CONTENT, and
# BOTH directions are mandatory:
#   POSITIVE — a real two-turn run (responses_tool.sse + the stub MCP
#     server, --max-turns 2) must RESOLVE the call's row: the log carries a
#     row for call_00_DgJfXOD0j0bvOV7jB0tl0124 with pending:false and an
#     outcome bounded from the stub-ok result text.  Without this half, a
#     join that NEVER fires would pass the negative half perfectly — a no-op
#     join is indistinguishable from a correct one, and that is the trap.
#   NEGATIVE — an UNFIREABLE join must be REPORTED: a run whose second
#     request never replays the call (--max-turns 1: the call is decoded and
#     never answered) must leave the call_id named as UNRESOLVED, on stderr
#     AND in a terminal proxy-exit summary row in the log itself — a log
#     merely missing its outcome half must never look like one where nothing
#     needed joining.
#   MUTATION BLIND — build/fx-hostgate-mutant is THIS proxy source with the
#     resolution pass compiled OUT (FH_MUTANT_NO_JOIN).  Run through the
#     POSITIVE scenario it still exits 0, the stub-ok result still crosses
#     the wire, and NO row resolves — a WRONG RECORD, not a crash.  The gate
#     must flip its clean pass to a fail on exactly this fixture, by content.
#   BOUND (P2 fix) — every model-controlled FREE-TEXT field (true_name, args,
#     outcome) must arrive in the log capped at FH_BOUND with an explicit
#     `...[TRUNCATED from N bytes]` marker, while a normal-length field is
#     VERBATIM and call_id — THE JOIN KEY, not free text — renders verbatim
#     (stated exemption: a truncated key is a different key; its length is
#     transitively bounded by the frame cap).  An arm that never exercises
#     an over-long value cannot test the bound, so the bound phase drives an
#     800-byte name through the real proxy, and build/fx-hostgate-unbound
#     (FH_MUTANT_NO_BOUND: bound_copy compiled OUT) must flip the phase to a
#     fail by content — unbounded text in an append-only host log is a wrong
#     record, not a crash.
#   NO POLICY CLAIM — no policy has run in P2, so no row may carry a verdict
#     field (`verdict`, `allowed`, `author`, `refusal_name`, `reason`,
#     `denial_text`): those are P3/P5's, and their absence is asserted so
#     P3's arrival will be visible in the record rather than implied.  (P3
#     honors this from the OTHER side: its phases ARM the policy with
#     --deny while these P2 phases run unarmed, so these row shapes stay
#     exactly as asserted.)
#
# P3 DIRECTION (stated up front): a decode-leg REWRITE MISS is a SILENT
#   ALLOW — the run looks fine (rc 0, the log claims a denial), and the
#   only witness that anything is wrong is that the TRUE NAME EXECUTED in
#   the guest.  So the P3 phases judge by CONTENT, never by exit status,
#   and the dispatch MARKER (a stub MCP server that records a dispatch)
#   is the instrument: the stub models the REAL verbs server
#   (fx-verbs-server.c:2669-2674 — find_verb(name)==NULL -> -32602) and
#   touches its marker ONLY for the KNOWN verb name get_weather, refusing
#   anything else.  BOTH directions are mandatory:
#   DENIED — the policy denies get_weather under the ALLOW-ALL config (the
#     worst case): the guest's transcript carries the RESERVED name
#     fx_host_denied (and never the true name), the marker is ABSENT
#     (nothing executed), the dumped outbound frame of the NEXT turn
#     carries the RESTORED true name and the denial text as the call's
#     output, and the log row names the honest author (denylist — never
#     ops/claim, which do not exist yet).
#   ACCEPTED — with the call not on the denylist, the call crosses
#     VERBATIM (the true name in the guest's transcript), the marker IS
#     touched, and the outgoing frame is NOT rewritten.  Without this arm
#     a proxy that denied EVERYTHING would pass the denied arm perfectly.
#   PRE-FIX CONTROL — build/fx-hostgate-norewrite (FH_MUTANT_NO_REWRITE:
#     the P2-era behavior pinned, rewrites compiled out while the record
#     still runs) forwards the true name of a call the log says was
#     denied: the stub DISPATCHES and the marker is PRESENT.  That is the
#     asymmetry — the denied arm's marker-absence is the gate's doing, not
#     the scenario's.
#   COMPLETENESS MUTANT — build/fx-hostgate-blindadd
#     (FH_MUTANT_NO_ADDED_REWRITE) removes ONLY the output_item.added
#     rewrite and keeps done/completed: the guest's accumulator is fed by
#     the added event alone (openai_responses.c:146-161), so it
#     accumulates the TRUE name and DISPATCHES — marker PRESENT while the
#     log claims a denial.  A partial rewriter is an allow; the gate MUST
#     catch it.
#
# P4 DIRECTION (stated up front): a NAME COLLISION is a SILENT ALLOW — a
#   reserved name that matches a catalog verb is CALLABLE, and an allow-all
#   lane dispatches it.  So P4 asserts a STARTUP REFUSAL (collision,
#   unparseable name, stale catalog pin — each with a build of the SAME SOURCE
#   where the check is absent and the proxy STARTS), and the collision arm
#   MEASURES the silent allow end to end (marker + transcript + a log that
#   claims a denial).  A provenance phase re-checks the proxy's pinned catalog
#   against the VERBS[] table in tools/fx-verbs-server.c and against a pin
#   restated here: two independent edits have to agree, so a future verb
#   surfaces as a failure rather than as a collision later.
#
# P6 DIRECTION: `--ops-policy-dir` arms THE OPERATOR as a real policy author
#   (the second of the design's two authors) beside the P3 placeholder
#   denylist, which STAYS.  The seat PORTS the in-guest ops evaluation
#   (tools/fx-verbs-server.c:774-1573) — the PINS check, the alias table with
#   the TWO-FORM pattern grammar (re-run at the new seat: an ambiguous glob
#   refuses at startup, and the exact-vs-subtree semantics are executed), the
#   per-call fact injection, the `denied` query and deny-more-only.  THE
#   D1/D2 SPLIT IS DETERMINED FROM THE RULE TEXT and NAMED in the startup
#   line: D1 (protected pathclass) is evaluated HERE; D2 (boot-verdict × the
#   compiled-in floor) needs live in-guest state and stays IN-GUEST — the
#   seat loads the artifact WHOLE but never injects `writable`/`boot_verdict`,
#   so D2 is INERT BY CONSTRUCTION, and the seat says it has NO FLOOR of its
#   own.  FAILURE DIRECTIONS pinned: a seat that does not deny what the pinned
#   policy denies is FAIL-OPEN (the pre-fix control executes it); a seat that
#   binds the floor it cannot see OVER-DENIES (the D2-bound control); a seat
#   matching the RAW path against the pinned patterns is a SILENT ALLOW on the
#   spellings the in-guest seat canonicalizes and refuses.
#
# P5 DIRECTION: `--require-justification` arms the tools injection (the model
#   is TOLD what is required) AND the judgement (the host CHECKS it).  Its
#   named failure shape is the DEAD AGENT: a schema the model cannot satisfy
#   denies everything, nothing executes, and the logs look protective — so the
#   gate asserts the DENIAL-RATE INSTRUMENT (per-turn rows, run aggregate, the
#   loud 100%-denied line) reports that shape, and has its own mutation blind
#   (FH_MUTANT_NO_DENIAL_RATE) to prove the report is load-bearing.  The
#   judgement reads the ARGUMENT ACCUMULATOR the guest dispatches (the deltas,
#   openai_responses.c:171-194) — a judge reading the done event's own field
#   denies honest calls, so that misreading is pinned as a pre-fix control
#   (FH_MUTANT_JUDGE_DONE_ARGS).  A justified call must still EXECUTE and the
#   verb must receive the justification RIDING WITH THE CALL (the stub records
#   the arguments it is handed): zero guest change, and the gate's
#   differential probe re-verifies per-verb unknown-key tolerance against the
#   REAL verbs server instead of trusting the source line.
#
# THE ARM/CONTROL PAIR THAT IS THE PROOF:
#   CONTROL (no proxy): FX_CHARDEV at the marked canned fixture AS A REGULAR
#     FILE — the offline arm's own shape (tools/stage-guest.sh host
#     pre-check, stage-guest.sh:527-539).  Untouched by this slice.
#   ARM (transparent): the same marked fixture served VERBATIM through
#     build/fx-hostgate on a PTY pair.  The guest harness is UNCHANGED (zero
#     guest change is the design): only the chardev path differs between the
#     arms.
#   Both run the WHOLE guest loop to the same MARKER — "hello" substituted
#   exactly as tools/stage-guest.sh:355 does (the QUOTED JSON string only,
#   so the reasoning sentence that merely mentions the word is untouched),
#   MARKER = tools/stage-guest.sh:81's FX-GUEST-LOOP-OK-8f31.
#
# MUTATION BLIND: a second proxy that speaks the frame contract but is NOT
# stream-transparent (it keeps only response.created and response.completed)
# must turn the clean pass into a mismatch.  The mutated run even EXITS 0 —
# response.completed still arrives, so the guest finishes cleanly with no
# final-answer text: exactly the silent shape this slice exists to exclude,
# caught by the marker and only by the marker.
#
# MEASUREMENT (the two mechanics slice P1 was asked to MEASURE, driven live,
# not assumed): the reopen arm runs TWO guest turns through ONE proxy
# process.  The guest opens and closes the chardev PER TURN
# (openai_responses.c:226/:292), so two served frames prove the slave path
# stayed valid across close/reopen, and the proxy's boundary lines show the
# master's EIO treated as a turn boundary, not a fatal error.
#
# Env knobs: KEEP_TMP=1 keeps the mktemp dir; FX_FIXTURE_DIR overrides the
# recorded SSE fixtures' location.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN="$ROOT/build/fx-agent"
GATE="$ROOT/build/fx-hostgate"
GATEMUT="$ROOT/build/fx-hostgate-mutant"
GATEUNB="$ROOT/build/fx-hostgate-unbound"
GATENRW="$ROOT/build/fx-hostgate-norewrite"
GATEADD="$ROOT/build/fx-hostgate-blindadd"
GATESI="$ROOT/build/fx-hostgate-singleitem"
GATENOS="$ROOT/build/fx-hostgate-nosubst"
# P4/P5: the contract + justification builds, every one from the SAME source
GATENONAME="$ROOT/build/fx-hostgate-nonamecheck"     # contract compiled out + a COLLIDING reserved name
GATENONAMEBAD="$ROOT/build/fx-hostgate-nonamebad"    # contract compiled out + an UNPARSEABLE reserved name
GATECOLLIDE="$ROOT/build/fx-hostgate-collide"        # reserved name = a catalog verb (real build: REFUSES)
GATEBADNAME="$ROOT/build/fx-hostgate-badname"        # reserved name fails the guest's charset (REFUSES)
GATEBADPIN="$ROOT/build/fx-hostgate-badpin"          # stale catalog pin (REFUSES)
GATENOTOOLS="$ROOT/build/fx-hostgate-notools"        # the tools injection compiled out
GATENOJUST="$ROOT/build/fx-hostgate-nojustify"       # the justification check compiled out
GATENODRATE="$ROOT/build/fx-hostgate-nodrate"        # the denial-rate instrument compiled out
GATEDONEARGS="$ROOT/build/fx-hostgate-doneargs"      # the judge reads the done event's field (pre-fix control)
# P6 (the operator author at the host seat), every one from the SAME source
GATENOOPS="$ROOT/build/fx-hostgate-noops"            # the ops seat compiled out (PRE-FIX control, fail-open)
GATEOPSFLOOR="$ROOT/build/fx-hostgate-opsfloor"      # the seat binds the floor fact it cannot see (D2-bound control)
GATEOPSNOCANON="$ROOT/build/fx-hostgate-opsnocanon"  # raw path matching (canonicalization blind)
FIX="${FX_FIXTURE_DIR:-$ROOT/tests/fixtures}"
MARKER="FX-GUEST-LOOP-OK-8f31"
SENTINEL="hostgate-p1-probe"
# the call the tool fixture carries (the join key for every P2 assert)
CALLID="call_00_DgJfXOD0j0bvOV7jB0tl0124"
# the two calls the interleave/sequential fixtures carry (P3-fix)
CALL_A="call_A_0001"  # get_weather
CALL_B="call_B_0002"  # fx_write
# the policy fields RESERVED for P3/P5/P6 — their presence in a P2 row is a
# claim wider than the evidence (no policy has run).  allow_scope (P6-fix) is
# the ALLOWED row's own seat-scoped reading: it is a verdict field too, so a
# row carrying it with NO policy behind it is the same over-claim.
POLICY_FIELDS="verdict allowed author allow_scope refusal_name reason denial_text"

fail() { echo "FAIL $*" >&2; exit 1; }

[ -x "$BIN" ] || fail "phase 0: $BIN missing — run make first"
[ -x "$GATE" ] || fail "phase 0: $GATE missing — run make first"
[ -x "$GATEMUT" ] || fail "phase 0: $GATEMUT missing — run make first"
[ -x "$GATEUNB" ] || fail "phase 0: $GATEUNB missing — run make first"
[ -x "$GATENRW" ] || fail "phase 0: $GATENRW missing — run make first"
[ -x "$GATEADD" ] || fail "phase 0: $GATEADD missing — run make first"
[ -x "$GATESI" ] || fail "phase 0: $GATESI missing — run make first"
[ -x "$GATENOS" ] || fail "phase 0: $GATENOS missing — run make first"
for b in "$GATENONAME" "$GATENONAMEBAD" "$GATECOLLIDE" "$GATEBADNAME" "$GATEBADPIN" \
         "$GATENOTOOLS" "$GATENOJUST" "$GATENODRATE" "$GATEDONEARGS" \
         "$GATENOOPS" "$GATEOPSFLOOR" "$GATEOPSNOCANON"; do
    [ -x "$b" ] || fail "phase 0: $b missing — run make first"
done
[ -f "$FIX/responses_simple.sse" ] || fail "phase 0: fixture $FIX/responses_simple.sse missing"
[ -f "$FIX/responses_tool.sse" ] || fail "phase 0: fixture $FIX/responses_tool.sse missing"
[ -f "$FIX/responses_interleaved.sse" ] || fail "phase 0: fixture $FIX/responses_interleaved.sse missing"
[ -f "$FIX/responses_sequential.sse" ] || fail "phase 0: fixture $FIX/responses_sequential.sse missing"
[ -f "$FIX/responses_justified.sse" ] || fail "phase 0: fixture $FIX/responses_justified.sse missing"

TMP=$(mktemp -d)
PROXIES=""
cleanup() {
    for p in $PROXIES; do kill "$p" 2>/dev/null; done
    [ "${KEEP_TMP:-0}" = 1 ] || rm -rf "$TMP"
}
trap cleanup EXIT
echo "== tmp: $TMP"

# pyq <logfile> <python-expr over `rows`> — evaluate an expression over the
# log's parsed JSONL rows (house style: python3 for JSON, no jq dependency).
# A row that fails to parse raises -> nonzero rc -> the assert fails.
pyq() {
    python3 - "$1" "$2" <<'PY'
import json, sys
rows = []
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if line:
            rows.append(json.loads(line))
print(eval(sys.argv[2]))
PY
}

# assert_no_policy_fields <logfile> — NO P2 row may claim a verdict: no
# policy has run in this slice (the brief's most-repeated failure shape).
assert_no_policy_fields() {
    local n
    n=$(pyq "$1" "len([1 for r in rows for k in ('verdict','allowed','author','allow_scope','refusal_name','reason','denial_text') if k in r])") \
        || fail "a row of $1 does not parse as JSONL"
    [ "$n" -eq 0 ] || fail "$1 carries policy fields ($POLICY_FIELDS) — a verdict claim with no policy behind it"
}

# drive_frame <slave-path> — one minimal request frame straight down the
# chardev, then drain the served stream to response.completed and close (the
# proxy's own turn-end cue).  The bound phases use this instead of a full
# guest run: the property under test is the proxy's decode-side rendering,
# which is guest-independent, and this arm isolates exactly that.
drive_frame() {
    python3 - "$1" <<'PY'
import json, os, select, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_APPEND)
frame = json.dumps({"model": "m", "stream": True,
                    "input": [{"type": "message", "role": "user", "content": "hi"}]})
os.write(fd, f"{len(frame)}\n{frame}".encode())
deadline = time.time() + 10
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 2)
    if not r:
        continue
    b = os.read(fd, 65536)
    if not b or b.count(b"response.completed"):
        break
os.close(fd)
PY
}

# The harness's runtime config: NO mcp servers (the staged lane's own shape,
# tools/stage-guest.sh:337-345).  The `= [] : List ...` annotations are
# MANDATORY — dhall-c cannot infer an unannotated empty list and the whole
# config fail-opens to empty without them (tests/test_resume.sh records the
# same hazard).
mkdir -p "$TMP/cfg"
cat > "$TMP/cfg/config.dhall" <<'DHALL'
{ agents =
  [ { name = "fx"
    , agent_type = "agent"
    , mcp_servers = [] : List { command : Text, args : List Text }
    }
  ]
}
DHALL

# The marked fixture: quoted-"hello" -> MARKER, the exact stage-guest.sh:355
# substitution.  Two byte-identical copies: the CONTROL arm's file (the guest
# appends its request frame to it — O_APPEND) and the proxy's upstream (read
# whole at proxy start, never written).
mark_fixture() { # <dest>
    sed "s/\"hello\"/\"$MARKER\"/g" "$FIX/responses_simple.sse" > "$1" \
        || fail "cannot write the marked fixture $1"
}
mark_fixture "$TMP/upstream.sse"
nsub=$(grep -o "$MARKER" "$TMP/upstream.sse" | wc -l | tr -d ' ')
[ "$nsub" -ge 1 ] || fail "phase 0: the marked fixture carries no marker — the substitution did not fire"
echo "== fixture marked: $nsub occurrence(s) of \"hello\" -> $MARKER"

# run <chardev> <datadir> [extra argv...] — the guest harness, offline shape
# (the stage-guest env quad: FX_CHARDEV / FX_AGENT_CONFIG_DIR /
# FX_AGENT_DATA / HOME).
run() {
    local dev="$1"
    local data="$2"
    shift 2
    FX_CHARDEV="$dev" FX_AGENT_CONFIG_DIR="$TMP/cfg" \
    FX_AGENT_DATA="$data" HOME="$TMP" \
        "$BIN" -p "$SENTINEL" --agent fx --output text "$@"
}

# wait_for_slave <pathfile> <proxy pid> <proxy errlog> — bounded, loud.
wait_for_slave() {
    local i=0
    while [ ! -s "$1" ] && [ "$i" -lt 200 ]; do # <= 10 s
        kill -0 "$2" 2>/dev/null \
            || fail "the proxy died before publishing its slave path ($(tail -3 "$3" | tr '\n' ' '))"
        sleep 0.05
        i=$((i + 1))
    done
    [ -s "$1" ] || fail "the proxy never published its slave path ($1)"
}

# wait_for_proxy_exit <pid> <errlog> — bounded reap; a hung proxy is a FAIL,
# never a hang (the gate must always end).  THE BOUND IS MEASURED, not chosen:
# the OVERSIZE arms push an 17.8 MiB stream through a 4 KiB pty line discipline,
# and draining it was measured at 11.4 s on this host — a 10 s bound made those
# arms a race they could lose (they did, twice, under load, with the proxy
# simply still writing).  40 s leaves room for that transfer and still fails a
# proxy that is genuinely stuck.
wait_for_proxy_exit() {
    local i=0
    while kill -0 "$1" 2>/dev/null && [ "$i" -lt 400 ]; do # <= 40 s
        sleep 0.1
        i=$((i + 1))
    done
    if kill -0 "$1" 2>/dev/null; then
        tail -5 "$2" >&2 || true
        fail "the proxy (pid $1) did not exit within 40s (the bound of the wait loop above) — see log above"
    fi
}

echo "== phase 1: CONTROL — the direct file arm, no proxy (stage-guest pre-check shape)"
mkdir -p "$TMP/data-control"
cp "$TMP/upstream.sse" "$TMP/control.sse"
out=$(run "$TMP/control.sse" "$TMP/data-control" --max-turns 3)
rc=$?
[ "$rc" -eq 0 ] || fail "phase 1: control run rc=$rc"
[ "$out" = "$MARKER" ] || fail "phase 1: control printed '$out', want exactly $MARKER"
echo "   OK control (direct file): rc=0, stdout is exactly the MARKER"

echo "== phase 2: ARM — the whole guest loop THROUGH the transparent proxy (pty pair)"
mkdir -p "$TMP/data-proxy"
"$GATE" --upstream "$TMP/upstream.sse" --slave-file "$TMP/slave1" --log "$TMP/log-arm.jsonl" --turns 1 \
    2> "$TMP/proxy1.err" &
PROXY1=$!
PROXIES="$PROXIES $PROXY1"
wait_for_slave "$TMP/slave1" "$PROXY1" "$TMP/proxy1.err"
DEV1=$(cat "$TMP/slave1")
echo "   proxy slave: $DEV1"
out=$(run "$DEV1" "$TMP/data-proxy" --max-turns 3)
rc=$?
[ "$rc" -eq 0 ] || { sed -n '1,10p' "$TMP/proxy1.err" >&2; fail "phase 2: proxy-arm run rc=$rc"; }
[ "$out" = "$MARKER" ] || fail "phase 2: proxy arm printed '$out', want exactly $MARKER"
wait_for_proxy_exit "$PROXY1" "$TMP/proxy1.err"
wait "$PROXY1"
prc=$?
[ "$prc" -eq 0 ] || fail "phase 2: the proxy exited rc=$prc"
grep -q "turn 1: request frame" "$TMP/proxy1.err" \
    || fail "phase 2: the proxy never logged a served frame — the arm did not actually cross it"
grep -q "served" "$TMP/proxy1.err" \
    || fail "phase 2: the proxy never logged the served stream — the arm did not actually cross it"
[ -s "$TMP/log-arm.jsonl" ] || fail "phase 2: the one log is missing/empty — the arm recorded nothing"
assert_no_policy_fields "$TMP/log-arm.jsonl"
nrows=$(pyq "$TMP/log-arm.jsonl" "len([r for r in rows if 'call_id' in r])") \
    || fail "phase 2: log-arm.jsonl is not JSONL"
[ "$nrows" -eq 0 ] || fail "phase 2: $nrows call rows on a fixture with ZERO tool calls — the decoder hallucinates rows"
nexit=$(pyq "$TMP/log-arm.jsonl" "len([r for r in rows if r.get('type')=='proxy-exit'])") \
    || fail "phase 2: log-arm.jsonl is not JSONL"
[ "$nexit" -eq 1 ] || fail "phase 2: expected exactly 1 proxy-exit summary row, got $nexit — the record is not closed"
echo "   OK arm (through fx-hostgate): rc=0, stdout is exactly the MARKER; the proxy served the frame and the stream; the log records ZERO calls on a call-free fixture and closes with an exit row"

echo "== phase 3: MUTATION BLIND — a mangling proxy must flip the clean pass to a fail"
cat > "$TMP/mutant_proxy.py" <<'PY'
# The mutant: speaks the same chardev contract (pty pair, raw mode, reads the
# "<len>\n<json>" frame) but is NOT stream-transparent — it keeps only
# response.created and response.completed and drops every other SSE event.
# On exactly this fixture the final-answer text never arrives, while the run
# still finishes CLEANLY (completed arrives; the guest's loop ends normally):
# the silent shape, catchable only by marker equality.
import os
import sys
import time
import tty

upstream, slave_file, turns = sys.argv[1], sys.argv[2], int(sys.argv[3])
log = lambda msg: print(f"mutant-proxy: {msg}", file=sys.stderr, flush=True)

master, slave = os.openpty()
tty.setraw(master)  # same raw line discipline as fx-hostgate
with open(slave_file, "w") as f:
    f.write(os.ttyname(slave) + "\n")
os.close(slave)

data = open(upstream, "rb").read()
keep = [e for e in data.split(b"\n\n")
        if b"response.created" in e or b"response.completed" in e]
mangled = b"\n\n".join(keep)
if not mangled.endswith(b"\n\n"):
    mangled += b"\n\n"

def read_frame(fd):
    # the mutant closes the slave fd at startup, so the master read returns
    # EIO until the guest opens it — the same boundary fx-hostgate retries
    # through; only a sustained stall (10 s) is fatal here.
    deadline = time.time() + 10
    digits = b""
    while True:
        try:
            b = os.read(fd, 1)
        except OSError:
            if time.time() > deadline:
                return None
            time.sleep(0.05)
            continue
        if not b:
            if time.time() > deadline:
                return None
            time.sleep(0.05)
            continue
        if b == b"\n":
            n = int(digits)
            break
        digits += b
        if len(digits) > 24:
            log("frame header too long")
            os._exit(1)
    left = n
    while left:
        try:
            chunk = os.read(fd, min(4096, left))
        except OSError:
            return None
        if not chunk:
            return None
        left -= len(chunk)
    return n

served = 0
while turns < 0 or served < turns:
    n = read_frame(master)
    if n is None:
        log("boundary: guest closed before a complete frame")
        os._exit(1)
    served += 1
    log(f"turn {served}: frame {n} bytes; serving {len(mangled)} mangled bytes")
    off = 0
    while off < len(mangled):
        try:
            off += os.write(master, mangled[off:])
        except OSError:
            log("boundary: guest left mid-stream")
            off = len(mangled)
# same close-wait as fx-hostgate: an exit now could close the master while
# kernel-staged bytes are still unread (the guest would see a truncation it
# cannot distinguish from EOF); wait for the guest's own turn-end close.
import select, time
deadline = time.time() + 10
while time.time() < deadline:
    r, _, _ = select.select([master], [], [], 0.5)
    if not r:
        continue
    try:
        b = os.read(master, 4096)
    except OSError:
        log("boundary: guest closed the device; clean exit")
        os._exit(0)
    if not b:
        log("boundary: guest closed the device; clean exit")
        os._exit(0)
    log(f"unexpected {len(b)} extra bytes after the last turn; ignored")
log("exit: no guest close within 10s; exiting anyway")
os._exit(0)
PY
mkdir -p "$TMP/data-mutant"
python3 "$TMP/mutant_proxy.py" "$TMP/upstream.sse" "$TMP/slave2" 1 \
    2> "$TMP/proxy2.err" &
PROXY2=$!
PROXIES="$PROXIES $PROXY2"
wait_for_slave "$TMP/slave2" "$PROXY2" "$TMP/proxy2.err"
DEV2=$(cat "$TMP/slave2")
out=$(run "$DEV2" "$TMP/data-mutant" --max-turns 3)
rc=$?
[ "$rc" -eq 0 ] || fail "phase 3: mutant-arm run rc=$rc — the mutation must be silent to the exit status, not a crash"
[ "$out" != "$MARKER" ] || fail "phase 3: the mangled stream STILL produced the MARKER — the gate is blind on exactly its fixture"
grep -q "turn 1: frame" "$TMP/proxy2.err" \
    || fail "phase 3: the mutant never served a frame — the arm did not actually cross it"
wait_for_proxy_exit "$PROXY2" "$TMP/proxy2.err"
wait "$PROXY2"
echo "   OK mutant caught: the run exits 0 but stdout '$out' != MARKER — the gate discriminates"

echo "== phase 4: MEASUREMENT — two guest turns through ONE proxy (per-turn reopen + EIO boundary)"
# MEASURED (this gate's own archaeology): with mcp_servers = [] a tool-call
# turn ENDS THE RUN before any second turn — agent_loop.c:758
# `if (!tool_srv) break;` fires after the decode, the assistant tool_call is
# never appended, and the loop exits rc 0 with one chardev frame.  So the
# reopen arm needs a REAL (harmless) MCP server: a stub that answers the
# initialize/tools-call handshake and returns a fixed text (mcp_client.c
# spawns it per call: initialize id=1, tools/call id=2).
cat > "$TMP/mcp_stub.py" <<'PY'
#!/usr/bin/env python3
import json
import sys

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        req = json.loads(line)
    except ValueError:
        continue
    m = req.get("method")
    if m == "initialize":
        print(json.dumps({"jsonrpc": "2.0", "id": req.get("id"), "result": {
            "protocolVersion": req.get("params", {}).get("protocolVersion"),
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "hostgate-stub", "version": "0"}}}), flush=True)
    elif m == "tools/call":
        print(json.dumps({"jsonrpc": "2.0", "id": req.get("id"), "result": {
            "content": [{"type": "text", "text": "stub-ok"}]}}), flush=True)
    # notifications (notifications/initialized): no reply
PY
mkdir -p "$TMP/data-reopen" "$TMP/cfg-reopen"
cat > "$TMP/cfg-reopen/config.dhall" <<DHALL
{ agents =
  [ { name = "fx"
    , agent_type = "agent"
    , mcp_servers =
      [ { command = "$TMP/mcp_stub.py", args = [] : List Text } ]
    }
  ]
}
DHALL
chmod +x "$TMP/mcp_stub.py"
sed "s/\"hello\"/\"$MARKER\"/g" "$FIX/responses_tool.sse" > "$TMP/upstream2.sse"
"$GATE" --upstream "$TMP/upstream2.sse" --slave-file "$TMP/slave3" --log "$TMP/log-reopen.jsonl" --turns 2 \
    2> "$TMP/proxy3.err" &
PROXY3=$!
PROXIES="$PROXIES $PROXY3"
wait_for_slave "$TMP/slave3" "$PROXY3" "$TMP/proxy3.err"
DEV3=$(cat "$TMP/slave3")
out=$(FX_CHARDEV="$DEV3" FX_AGENT_CONFIG_DIR="$TMP/cfg-reopen" \
    FX_AGENT_DATA="$TMP/data-reopen" HOME="$TMP" \
    "$BIN" -p "$SENTINEL" --agent fx --max-turns 2 --output text)
rc=$?
[ "$rc" -eq 0 ] || { sed -n '1,10p' "$TMP/proxy3.err" >&2; fail "phase 4: reopen run rc=$rc"; }
grep -q "turn 1: request frame" "$TMP/proxy3.err" \
    || fail "phase 4: the proxy never served turn 1"
grep -q "turn 2: request frame" "$TMP/proxy3.err" \
    || fail "phase 4: the proxy served fewer than 2 frames — the per-turn reopen did not happen"
grep -q "boundary: guest closed the device" "$TMP/proxy3.err" \
    || fail "phase 4: the proxy never logged the close/reopen boundary (master EIO between turns)"
grep -q "stub-ok" "$TMP/data-reopen"/sessions/*/messages.jsonl \
    || fail "phase 4: the stub tool never dispatched — turn 2 is not proven to be a real second turn"
wait_for_proxy_exit "$PROXY3" "$TMP/proxy3.err"
wait "$PROXY3"
prc=$?
[ "$prc" -eq 0 ] || fail "phase 4: the proxy exited rc=$prc"
echo "   OK reopen: one proxy process served two guest turns (open -> close -> reopen on the same slave path); the master's EIO was a boundary, not a failure; the second turn dispatched through the stub server"

echo "== phase 5: P2 POSITIVE — a real two-turn run RESOLVES the call_id (the join MUST fire)"
# Two turns, the tool fixture, the stub MCP server: turn 1 decodes the
# get_weather call (a row goes into the log, pending:true); the guest
# dispatches it through the stub and replays the result as a
# function_call_output in turn 2's request — down the SAME chardev — so the
# proxy itself sees the join close.  The canned upstream replays identically
# every turn, so turn 2 decodes the SAME call_id again and that second
# instance legitimately stays pending (the run is capped at 2 turns): the
# exactness asserts below pin that only the ANSWERED instance resolves.
mkdir -p "$TMP/data-join"
"$GATE" --upstream "$TMP/upstream2.sse" --slave-file "$TMP/slave4" \
    --log "$TMP/log-join.jsonl" --turns 2 2> "$TMP/proxy4.err" &
PROXY4=$!
PROXIES="$PROXIES $PROXY4"
wait_for_slave "$TMP/slave4" "$PROXY4" "$TMP/proxy4.err"
DEV4=$(cat "$TMP/slave4")
out=$(FX_CHARDEV="$DEV4" FX_AGENT_CONFIG_DIR="$TMP/cfg-reopen" \
    FX_AGENT_DATA="$TMP/data-join" HOME="$TMP" \
    "$BIN" -p "$SENTINEL" --agent fx --max-turns 2 --output text)
rc=$?
[ "$rc" -eq 0 ] || { sed -n '1,10p' "$TMP/proxy4.err" >&2; fail "phase 5: two-turn run rc=$rc"; }
grep -q "stub-ok" "$TMP/data-join"/sessions/*/messages.jsonl \
    || fail "phase 5: the stub tool never dispatched — the run is not the real two-turn scenario"
wait_for_proxy_exit "$PROXY4" "$TMP/proxy4.err"
wait "$PROXY4"
prc=$?
[ "$prc" -eq 0 ] || fail "phase 5: the proxy exited rc=$prc"
L="$TMP/log-join.jsonl"
[ -s "$L" ] || fail "phase 5: the one log is missing/empty"
n=$(pyq "$L" "len([r for r in rows if r.get('call_id')=='$CALLID'])") \
    || fail "phase 5: $L is not JSONL"
[ "$n" -eq 2 ] || fail "phase 5: expected 2 rows for $CALLID (one per turn's decode), got $n"
n=$(pyq "$L" "len([r for r in rows if r.get('call_id')=='$CALLID' and r.get('pending') is False])")
[ "$n" -eq 1 ] || fail "phase 5: expected exactly 1 RESOLVED row for $CALLID, got $n — THE JOIN DID NOT FIRE (the positive half)"
n=$(pyq "$L" "len([r for r in rows if r.get('call_id')=='$CALLID' and r.get('pending') is False and r.get('turn')==1 and isinstance(r.get('outcome'),str) and 'stub-ok' in r['outcome']])")
[ "$n" -eq 1 ] || fail "phase 5: the resolved row is not turn 1 with a stub-ok outcome — the join fired on the wrong leg"
n=$(pyq "$L" "len([r for r in rows if r.get('call_id')=='$CALLID' and r.get('args')=='{\"city\": \"Paris\"}'])")
[ "$n" -eq 2 ] || fail "phase 5: the decoded rows do not carry the call's arguments verbatim"
n=$(pyq "$L" "len([r for r in rows if r.get('call_id')=='$CALLID' and r.get('turn')==2 and r.get('pending') is True and r.get('outcome') is None])")
[ "$n" -eq 1 ] || fail "phase 5: the turn-2 instance should stay pending (it was never answered — the run is capped at 2 turns)"
n=$(pyq "$L" "len([r for r in rows if r.get('call_id')=='$CALLID' and r.get('session') is None and r.get('run') is None])")
[ "$n" -eq 2 ] || fail "phase 5: session/run must be explicit nulls (the wire carries no identity — do not let them silently grow values)"
n=$(pyq "$L" "len([r for r in rows if r.get('type')=='proxy-exit' and r.get('turns_served')==2 and any(u.get('call_id')=='$CALLID' for u in r.get('unresolved',[]))])")
[ "$n" -eq 1 ] || fail "phase 5: the exit summary row must name the never-answered turn-2 instance"
grep -q "UNRESOLVED" "$TMP/proxy4.err" \
    || fail "phase 5: the proxy's stderr never reported the pending turn-2 instance"
grep -q "$CALLID" "$TMP/proxy4.err" \
    || fail "phase 5: the stderr report does not name $CALLID"
assert_no_policy_fields "$L"
echo "   OK positive: turn 1's row RESOLVED by turn 2's function_call_output (outcome=stub-ok, args verbatim); the turn-2 instance is pending and NAMED by the exit report; no row carries a verdict field"

echo "== phase 6: P2 NEGATIVE — an unfireable join is REPORTED, by call_id"
# --max-turns 1: the call is decoded on turn 1 and the run ends BEFORE any
# dispatch (agent_loop.c:758 with no MCP server; also the last-turn break) —
# no second request ever replays the output, so the join CANNOT fire.  It
# must still be LOUD: pending row + stderr UNRESOLVED + an exit summary row
# in the log naming the call_id.  A silent missing outcome half would be
# indistinguishable from a record hole; this assert draws the line.
mkdir -p "$TMP/data-neg"
"$GATE" --upstream "$TMP/upstream2.sse" --slave-file "$TMP/slave5" \
    --log "$TMP/log-neg.jsonl" --turns 1 2> "$TMP/proxy5.err" &
PROXY5=$!
PROXIES="$PROXIES $PROXY5"
wait_for_slave "$TMP/slave5" "$PROXY5" "$TMP/proxy5.err"
DEV5=$(cat "$TMP/slave5")
out=$(run "$DEV5" "$TMP/data-neg" --max-turns 1)
rc=$?
[ "$rc" -eq 0 ] || { sed -n '1,10p' "$TMP/proxy5.err" >&2; fail "phase 6: one-turn run rc=$rc"; }
wait_for_proxy_exit "$PROXY5" "$TMP/proxy5.err"
wait "$PROXY5"
prc=$?
[ "$prc" -eq 0 ] || fail "phase 6: the proxy exited rc=$prc"
L="$TMP/log-neg.jsonl"
[ -s "$L" ] || fail "phase 6: the one log is missing/empty"
n=$(pyq "$L" "len([r for r in rows if r.get('call_id')=='$CALLID' and r.get('pending') is True and r.get('outcome') is None])") \
    || fail "phase 6: $L is not JSONL"
[ "$n" -eq 1 ] || fail "phase 6: expected exactly 1 pending row for $CALLID, got $n"
n=$(pyq "$L" "len([r for r in rows if r.get('type')=='proxy-exit' and any(u.get('call_id')=='$CALLID' for u in r.get('unresolved',[]))])")
[ "$n" -eq 1 ] || fail "phase 6: the log's exit summary does NOT report $CALLID as unresolved — an unfireable join sat silent in the record"
grep -q "UNRESOLVED" "$TMP/proxy5.err" \
    || fail "phase 6: the proxy's stderr never reported the unresolved call"
grep -q "$CALLID" "$TMP/proxy5.err" \
    || fail "phase 6: the stderr report does not name $CALLID"
assert_no_policy_fields "$L"
echo "   OK negative: the unfireable join is REPORTED — pending row in the log, exit summary naming $CALLID, stderr UNRESOLVED"

echo "== phase 7: P2 MUTATION BLIND — the join compiled OUT must flip the positive pass to a fail"
# build/fx-hostgate-mutant is THIS proxy source with FH_MUTANT_NO_JOIN: the
# frame parse still runs, the resolution never does.  On exactly the phase-5
# scenario the mutant exits 0 and the stub-ok output still crosses the wire
# (messages.jsonl proves it was fireable) — yet NO row resolves: a WRONG
# RECORD, not a crash.  The flip the gate asserts: the phase-5 positive
# assertion (a resolved row exists) FAILS on the mutant's log, while the
# mutant still reports the never-resolved calls loudly (it fails open in the
# record, visibly — that part of the contract survives the mutation).
mkdir -p "$TMP/data-mutjoin"
"$GATEMUT" --upstream "$TMP/upstream2.sse" --slave-file "$TMP/slave6" \
    --log "$TMP/log-mutant.jsonl" --turns 2 2> "$TMP/proxy6.err" &
PROXY6=$!
PROXIES="$PROXIES $PROXY6"
wait_for_slave "$TMP/slave6" "$PROXY6" "$TMP/proxy6.err"
DEV6=$(cat "$TMP/slave6")
out=$(FX_CHARDEV="$DEV6" FX_AGENT_CONFIG_DIR="$TMP/cfg-reopen" \
    FX_AGENT_DATA="$TMP/data-mutjoin" HOME="$TMP" \
    "$BIN" -p "$SENTINEL" --agent fx --max-turns 2 --output text)
rc=$?
[ "$rc" -eq 0 ] || fail "phase 7: mutant run rc=$rc — the mutant must be SILENT to the exit status (wrong record, not a crash)"
grep -q "stub-ok" "$TMP/data-mutjoin"/sessions/*/messages.jsonl \
    || fail "phase 7: the stub output never crossed — the join WAS fireable, the mutant must be judged on a fireable join"
wait_for_proxy_exit "$PROXY6" "$TMP/proxy6.err"
wait "$PROXY6"
prc=$?
[ "$prc" -eq 0 ] || fail "phase 7: the mutant proxy exited rc=$prc"
L="$TMP/log-mutant.jsonl"
[ -s "$L" ] || fail "phase 7: the mutant's log is missing/empty"
n=$(pyq "$L" "len([r for r in rows if r.get('call_id')=='$CALLID'])") \
    || fail "phase 7: $L is not JSONL"
[ "$n" -ge 1 ] || fail "phase 7: the mutant decoded no calls — it must be judged on the same decode, not a dead one"
n=$(pyq "$L" "len([r for r in rows if r.get('call_id')=='$CALLID' and r.get('pending') is False])")
[ "$n" -eq 0 ] || fail "phase 7: the mutant RESOLVED a row — the mutation did not take, the blind is vacuous"
n=$(pyq "$L" "len([r for r in rows if r.get('type')=='proxy-exit' and any(u.get('call_id')=='$CALLID' for u in r.get('unresolved',[]))])")
[ "$n" -eq 1 ] || fail "phase 7: the mutant did not report $CALLID unresolved — a wrong record must still fail open in the record"
grep -q "UNRESOLVED" "$TMP/proxy6.err" \
    || fail "phase 7: the mutant's stderr never reported the unresolved calls"
echo "   OK mutant caught: rc 0, the fireable output crossed, yet ZERO rows resolved — the phase-5 positive assertion flips to a fail on exactly this fixture, by content"

echo "== phase 8: P2-fix BOUND — an over-long model-controlled field arrives MARKED, a normal one VERBATIM, call_id (the key) untouched"
# An 800-byte function_call name driven straight through the REAL proxy
# (decode-side rendering is guest-independent — drive_frame isolates it):
# the log must carry the name capped at FH_BOUND=512 with the explicit
# marker naming the original length, while the SAME row's normal-length
# fields stay verbatim and call_id — the join key, exempt by stated
# decision — arrives full.  The exit row must obey the same rule when it
# repeats the fields.
LONGNAME=$(printf 'A%.0s' $(seq 1 800))
sed "s/\"name\":\"get_weather\"/\"name\":\"$LONGNAME\"/g" \
    "$TMP/upstream2.sse" > "$TMP/upstream-longname.sse" || fail "phase 8: cannot write the long-name fixture"
grep -q "$LONGNAME" "$TMP/upstream-longname.sse" \
    || fail "phase 8: the long-name fixture carries no over-long name — the arm never exercises the bound"
"$GATE" --upstream "$TMP/upstream-longname.sse" --slave-file "$TMP/slave7" \
    --log "$TMP/log-bound.jsonl" --turns 1 2> "$TMP/proxy7.err" &
PROXY7=$!
PROXIES="$PROXIES $PROXY7"
wait_for_slave "$TMP/slave7" "$PROXY7" "$TMP/proxy7.err"
DEV7=$(cat "$TMP/slave7")
drive_frame "$DEV7"
wait_for_proxy_exit "$PROXY7" "$TMP/proxy7.err"
wait "$PROXY7"
prc=$?
[ "$prc" -eq 0 ] || fail "phase 8: the proxy exited rc=$prc"
L="$TMP/log-bound.jsonl"
[ -s "$L" ] || fail "phase 8: the one log is missing/empty"
BN="'A'*(512-len('...[TRUNCATED from 800 bytes]'))+'...[TRUNCATED from 800 bytes]'"
n=$(pyq "$L" "len([r for r in rows if r.get('call_id')=='$CALLID' and r.get('true_name')==$BN and len(r['true_name'])==512])") \
    || fail "phase 8: $L is not JSONL"
[ "$n" -eq 1 ] || fail "phase 8: the 800-byte name is not capped at 512 with the explicit '[TRUNCATED from 800 bytes]' marker — UNBOUNDED model text in the log"
n=$(pyq "$L" "len([r for r in rows if r.get('call_id')=='$CALLID' and r.get('args')=='{\"city\": \"Paris\"}'])")
[ "$n" -eq 1 ] || fail "phase 8: the normal-length args are not verbatim — the bound must not touch short fields"
n=$(pyq "$L" "len([r for r in rows if r.get('call_id')=='$CALLID' and 'TRUNCATED' not in r['call_id']])")
[ "$n" -eq 1 ] || fail "phase 8: call_id was altered — the JOIN KEY renders verbatim by stated decision (a truncated key is a different key)"
n=$(pyq "$L" "len([r for r in rows if r.get('type')=='proxy-exit' and len(r.get('unresolved',[]))==1 and r['unresolved'][0]['call_id']=='$CALLID' and r['unresolved'][0]['true_name']==$BN])")
[ "$n" -eq 1 ] || fail "phase 8: the exit row must bound the repeated true_name and keep call_id full"
assert_no_policy_fields "$L"
echo "   OK bound: true_name 800B -> 512B + '[TRUNCATED from 800 bytes]'; args verbatim; call_id (the key) full; the exit row obeys the same rule"

echo "== phase 9: P2-fix BOUND MUTANT — the bound compiled OUT must flip phase 8 to a fail"
# build/fx-hostgate-unbound is THIS proxy source with bound_copy compiled
# out: the same 800-byte name arrives UNCAPPED and UNMARKED.  The mutant
# exits cleanly — unbounded text in an append-only host log is a WRONG
# RECORD, not a crash — so the flip is asserted by content: the phase-8
# assertion (capped + marked) FAILS on the mutant's log.
"$GATEUNB" --upstream "$TMP/upstream-longname.sse" --slave-file "$TMP/slave8" \
    --log "$TMP/log-unbound.jsonl" --turns 1 2> "$TMP/proxy8.err" &
PROXY8=$!
PROXIES="$PROXIES $PROXY8"
wait_for_slave "$TMP/slave8" "$PROXY8" "$TMP/proxy8.err"
DEV8=$(cat "$TMP/slave8")
drive_frame "$DEV8"
wait_for_proxy_exit "$PROXY8" "$TMP/proxy8.err"
wait "$PROXY8"
prc=$?
[ "$prc" -eq 0 ] || fail "phase 9: the mutant exited rc=$prc — the wrong record must be silent to the exit status, not a crash"
L="$TMP/log-unbound.jsonl"
[ -s "$L" ] || fail "phase 9: the mutant's log is missing/empty"
n=$(pyq "$L" "len([r for r in rows if r.get('true_name')=='A'*800 and 'TRUNCATED' not in r.get('true_name','')])") \
    || fail "phase 9: $L is not JSONL"
[ "$n" -eq 1 ] || fail "phase 9: the mutant's name row is not the full 800-byte verbatim string — the mutation did not take, the blind is vacuous"
n=$(pyq "$L" "len([r for r in rows if r.get('type')=='proxy-exit' and len(r.get('unresolved',[]))==1 and r['unresolved'][0]['true_name']=='A'*800])")
[ "$n" -eq 1 ] || fail "phase 9: the mutant's exit row does not repeat the unbounded name — the flip must cover both render sites"
n=$(pyq "$L" "len([r for r in rows if r.get('call_id')=='$CALLID'])")
[ "$n" -ge 1 ] || fail "phase 9: the mutant decoded no call — it must be judged on the same decode, not a dead one"
echo "   OK bound mutant caught: rc 0, the 800-byte name UNCAPPED in the call row AND the exit row — the phase-8 assertion flips to a fail on exactly its fixture, by content"

# ── P3: the decode gate (H2) + the outbound substitution ────────────────────
#
# The marker stub models the REAL verbs server: it touches its marker file
# ONLY for the KNOWN verb name get_weather (the dispatch record) and refuses
# anything else with -32602 exactly as fx-verbs-server.c:2669-2674 refuses
# an unknown name.  The marker path is BAKED INTO the script (the guest
# spawns MCP servers with a PATH-only env, mcp_client.c:243-260 — an env-var
# knob would silently never reach the stub, and the arm would be vacuous).
# DISCIPLINE (phase 10): a stub that touched its marker on ANY tools/call
# would fire on fx_host_denied too and the whole denied arm would be
# meaningless — so the refusal is pinned by driving the stub directly.
make_marker_stub() { # <script-path> <marker-path>
    cat > "$1" <<PY
#!/usr/bin/env python3
# The dispatch-recording stub, modelled on the real verbs server: KNOWN verb
# only -> do the work, touch the marker, answer; anything else -> -32602.
import json
import sys

MARKER = "$2"
KNOWN = "get_weather"

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        req = json.loads(line)
    except ValueError:
        continue
    m = req.get("method")
    if m == "initialize":
        print(json.dumps({"jsonrpc": "2.0", "id": req.get("id"), "result": {
            "protocolVersion": req.get("params", {}).get("protocolVersion"),
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "hostgate-marker-stub", "version": "0"}}}),
            flush=True)
    elif m == "tools/call":
        name = (req.get("params") or {}).get("name")
        if name == KNOWN:
            with open(MARKER, "a") as f:
                f.write("dispatched %s\n" % KNOWN)
            print(json.dumps({"jsonrpc": "2.0", "id": req.get("id"),
                              "result": {"content": [{"type": "text",
                                                      "text": "stub-ok-weather"}]}}),
                  flush=True)
        else:
            print(json.dumps({"jsonrpc": "2.0", "id": req.get("id"),
                              "error": {"code": -32602,
                                        "message": "unknown tool: %s" % name}}),
                  flush=True)
    # notifications (notifications/initialized): no reply
PY
    chmod +x "$1"
}

# make_multi_stub <script-path> <weather-marker> <write-marker> — the two-verb
# dispatch-recording stub for the interleave/sequential fixtures: get_weather
# and fx_write each touch their OWN marker (the dispatch record); anything
# else -> -32602 exactly as fx-verbs-server.c:2669-2674 refuses an unknown
# name.  Same discipline as the single-verb stub (phase 10): a stub that
# touched a marker on any tools/call would fire on fx_host_denied too and the
# marker assert would be vacuous, so the refusal is implicit in the name check.
make_multi_stub() { # <script-path> <weather-marker> <write-marker>
    cat > "$1" <<PY
#!/usr/bin/env python3
# Two-verb dispatch-recording stub: get_weather and fx_write each touch their
# OWN marker; anything else -> -32602 (the verbs server's unknown-name shape).
import json
import sys

MARKERS = {"get_weather": "$2", "fx_write": "$3"}

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        req = json.loads(line)
    except ValueError:
        continue
    m = req.get("method")
    if m == "initialize":
        print(json.dumps({"jsonrpc": "2.0", "id": req.get("id"), "result": {
            "protocolVersion": req.get("params", {}).get("protocolVersion"),
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "hostgate-multi-stub", "version": "0"}}}),
            flush=True)
    elif m == "tools/call":
        name = (req.get("params") or {}).get("name")
        if name in MARKERS:
            with open(MARKERS[name], "a") as f:
                f.write("dispatched %s\n" % name)
            print(json.dumps({"jsonrpc": "2.0", "id": req.get("id"),
                              "result": {"content": [{"type": "text",
                                                      "text": "ok-" + name}]}}),
                  flush=True)
        else:
            print(json.dumps({"jsonrpc": "2.0", "id": req.get("id"),
                              "error": {"code": -32602,
                                        "message": "unknown tool: %s" % name}}),
                  flush=True)
    # notifications (notifications/initialized): no reply
PY
    chmod +x "$1"
}

echo "== phase 10: P3 STUB DISCIPLINE — the marker fires ONLY for the known verb"
# Drive the stub DIRECTLY (no guest, no proxy): the reserved name must be
# REFUSED -32602 with the marker untouched, the known verb must dispatch and
# touch it.  If the stub touched its marker on any tools/call it would fire
# on fx_host_denied too and every later marker assert would be vacuous.
make_marker_stub "$TMP/mcp_marker.py" "$TMP/marker-disc"
python3 - "$TMP/mcp_marker.py" <<'PY'
import json, subprocess, sys

stub = sys.argv[1]

def rpc(method_req):
    p = subprocess.run([sys.executable, stub],
                       input=json.dumps(method_req) + "\n",
                       capture_output=True, text=True, timeout=10)
    return [json.loads(l) for l in p.stdout.splitlines() if l.strip()]

r = rpc({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
         "params": {"name": "fx_host_denied", "arguments": {}}})
err = [x for x in r if x.get("id") == 2 and x.get("error")]
assert err and err[0]["error"]["code"] == -32602, r
print("stub refused fx_host_denied with -32602 (unknown tool), as the verbs server would")
PY
rc=$?
[ "$rc" -eq 0 ] || fail "phase 10: the marker stub does not model the verbs server (rc=$rc)"
[ ! -e "$TMP/marker-disc" ] \
    || { rm -f "$TMP/marker-disc"; fail "phase 10: the stub touched its marker for fx_host_denied — the marker discipline is broken and every P3 arm would be vacuous"; }
make_marker_stub "$TMP/mcp_marker.py" "$TMP/marker-disc2"
python3 - "$TMP/mcp_marker.py" <<'PY'
import json, subprocess, sys
p = subprocess.run([sys.executable, sys.argv[1]],
                   input=json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                     "params": {"name": "get_weather", "arguments": {}}}) + "\n",
                   capture_output=True, text=True, timeout=10)
r = [json.loads(l) for l in p.stdout.splitlines() if l.strip()]
assert any(x.get("id") == 1 and x.get("result") for x in r), r
PY
rc=$?
[ "$rc" -eq 0 ] || fail "phase 10: the stub did not answer a direct get_weather call (rc=$rc)"
[ -f "$TMP/marker-disc2" ] || fail "phase 10: the stub never touched its marker for the KNOWN verb — the dispatch instrument is dead"
echo "   OK stub discipline: -32602 + no marker for fx_host_denied; marker touched ONLY for get_weather"

echo "== phase 11: P3 DENIED — the true name never crosses; nothing executes; the denial reaches the model"
# THE WORST CASE, as briefed: the ALLOW-ALL config (no tool lists at all —
# the staged lane's own shape), the policy denying get_weather.  Everything
# the gate asserts here is CONTENT: the run exits 0 and the log looks
# protective in EVERY arm, including the broken ones — only the transcript,
# the marker and the dumped outbound frame tell them apart.
mkdir -p "$TMP/data-deny" "$TMP/cfg-gate"
make_marker_stub "$TMP/mcp_marker.py" "$TMP/marker-deny"
cat > "$TMP/cfg-gate/config.dhall" <<DHALL
{ agents =
  [ { name = "fx"
    , agent_type = "agent"
    , mcp_servers = [ { command = "$TMP/mcp_marker.py", args = [] : List Text } ]
    }
  ]
}
DHALL
"$GATE" --upstream "$TMP/upstream2.sse" --slave-file "$TMP/slave9" \
    --log "$TMP/log-deny.jsonl" --dump-requests "$TMP/dump-deny.jsonl" \
    --deny get_weather --turns 2 2> "$TMP/proxy9.err" &
PROXY9=$!
PROXIES="$PROXIES $PROXY9"
wait_for_slave "$TMP/slave9" "$PROXY9" "$TMP/proxy9.err"
DEV9=$(cat "$TMP/slave9")
out=$(FX_CHARDEV="$DEV9" FX_AGENT_CONFIG_DIR="$TMP/cfg-gate" \
    FX_AGENT_DATA="$TMP/data-deny" HOME="$TMP" \
    "$BIN" -p "$SENTINEL" --agent fx --max-turns 2 --output text)
rc=$?
[ "$rc" -eq 0 ] || { sed -n '1,10p' "$TMP/proxy9.err" >&2; fail "phase 11: denied-arm run rc=$rc"; }
wait_for_proxy_exit "$PROXY9" "$TMP/proxy9.err"
wait "$PROXY9"
prc=$?
[ "$prc" -eq 0 ] || fail "phase 11: the proxy exited rc=$prc"
TR=$(ls "$TMP"/data-deny/sessions/*/messages.jsonl 2>/dev/null)
[ -f "$TR" ] || fail "phase 11: no guest transcript — the run is not the real scenario"
# (a) THE TRANSCRIPT: every dispatched tool name is the RESERVED name; the
# true name never reached the guest even as bytes; the guest's own refusal
# path produced the sentinel for the same call_id.
n=$(pyq "$TR" "len([1 for r in rows for tc in (r.get('tool_calls') or []) if tc.get('name')=='fx_host_denied' and tc.get('id')=='$CALLID'])")
[ "$n" -eq 1 ] || fail "phase 11: the transcript does not carry the call as fx_host_denied — the rewrite did not reach the guest's accumulator"
n=$(pyq "$TR" "len([1 for r in rows for tc in (r.get('tool_calls') or []) if tc.get('name')=='get_weather'])")
[ "$n" -eq 0 ] || fail "phase 11: the TRUE NAME get_weather reached the guest's transcript as a call name — THE INVARIANT IS BROKEN"
# The invariant is scoped to NAME POSITIONS (a parsed tool-call's name field),
# NOT to the raw byte string: the header's named residual is that model PROSE
# mentioning the verb deliberately crosses (and reasoning is not recorded in
# the transcript today, so a raw grep would pass only by that accident).  The
# two pyq asserts above are the real ones — the name-field checks — so no raw
# grep here; a future fixture whose reasoning mentions the verb must not
# false-fail the gate.
n=$(pyq "$TR" "len([1 for r in rows if r.get('role')=='tool' and r.get('tool_call_id')=='$CALLID' and r.get('content')=='(tool call failed)'])")
[ "$n" -eq 1 ] || fail "phase 11: the guest's sentinel '(tool call failed)' for the reserved name is missing — the structural backstop path did not run"
# (b) THE DISPATCH MARKER IS ABSENT — nothing executed
[ ! -e "$TMP/marker-deny" ] \
    || fail "phase 11: THE MARKER IS PRESENT — the denied call EXECUTED in the guest (a silent allow)"
# (c) THE OUTBOUND FRAME of the NEXT turn: the RESTORED true name in the
# function_call item AND the denial text as the call's output; the reserved
# name must NOT survive into the model-facing frame.
D="$TMP/dump-deny.jsonl"
[ -s "$D" ] || fail "phase 11: the dumped outbound frames are missing — the substitution cannot be asserted"
n=$(wc -l < "$D")
[ "$n" -eq 2 ] || fail "phase 11: expected 2 dumped frames (one per turn), got $n"
n=$(pyq "$D" "len([r for r in rows if any(i.get('type')=='function_call' and i.get('call_id')=='$CALLID' and i.get('name')=='get_weather' for i in r.get('input',[]))])")
[ "$n" -ge 1 ] || fail "phase 11: no dumped frame carries the RESTORED true name get_weather — the model would see a call it never made"
n=$(pyq "$D" "len([r for r in rows if any(i.get('type')=='function_call_output' and i.get('call_id')=='$CALLID' and isinstance(i.get('output'),str) and i['output'].startswith('(denied by host policy:') for i in r.get('input',[]))])")
[ "$n" -ge 1 ] || fail "phase 11: no dumped frame carries the DENIAL TEXT as the call's output — the model would never learn why"
n=$(pyq "$D" "len([r for r in rows if 'fx_host_denied' in json.dumps(r)])") \
    || fail "phase 11: dump-deny.jsonl is not JSONL"
[ "$n" -eq 0 ] || fail "phase 11: the reserved name survived into a model-facing frame — the restore is incomplete"
# (d) THE LOG ROW: the honest author, the refusal name, the reason — and
# the join closed with the guest's raw sentinel (the record keeps BOTH
# truths: what the guest wrote and what the model was told).
L="$TMP/log-deny.jsonl"
n=$(pyq "$L" "len([r for r in rows if r.get('call_id')=='$CALLID' and r.get('verdict')=='denied' and r.get('author')=='denylist' and r.get('refusal_name')=='denied-by-denylist' and isinstance(r.get('reason'),str) and 'denylist' in r['reason'] and isinstance(r.get('denial_text'),str) and r['denial_text'].startswith('(denied by host policy:')])")
[ "$n" -ge 1 ] || fail "phase 11: no row carries verdict=denied with the HONEST author (denylist), refusal_name and the denial text"
n=$(pyq "$L" "len([1 for r in rows for a in ('ops','claim') if r.get('author')==a])")
[ "$n" -eq 0 ] || fail "phase 11: a row claims author ops/claim — an author that DOES NOT EXIST yet (a record wider than the evidence)"
n=$(pyq "$L" "len([r for r in rows if r.get('call_id')=='$CALLID' and r.get('turn')==1 and r.get('pending') is False and r.get('outcome')=='(tool call failed)'])")
[ "$n" -eq 1 ] || fail "phase 11: the turn-1 row did not resolve with the guest's raw sentinel — the join is broken on the denied path"
n=$(pyq "$L" "len([1 for r in rows if r.get('type') in ('unjoined-output','echo-anomaly')])")
[ "$n" -eq 0 ] || fail "phase 11: telemetry anomaly rows in a CLEAN denied run — the instruments disagree with the rewrite"
# P3-fix: the pending-substitution instrument must NOT fire when the
# substitution actually happened (turn-2 substituted the denial text)
n=$(pyq "$L" "len([1 for r in rows if r.get('type')=='unresolved-substitution'])")
[ "$n" -eq 0 ] || fail "phase 11: an unresolved-substitution row in a clean denied run — the instrument false-fired on a substitution that happened"
echo "   OK denied: transcript=fx_host_denied (get_weather never crossed, not even as bytes); marker ABSENT (nothing executed); turn-2 frame carries the RESTORED name + the denial text; the row names author=denylist honestly"

echo "== phase 12: P3 ACCEPTED — the other direction: an allowed call crosses VERBATIM and executes"
# Armed with a name the fixture never calls (fx_write), so the denylist RAN
# (verdict allowed) but get_weather is not on it.  Without this arm a proxy
# that denied EVERYTHING would pass phase 11 perfectly.  Its own stub, so
# the marker is a clean instrument for this arm alone.
mkdir -p "$TMP/data-acc" "$TMP/cfg-acc"
make_marker_stub "$TMP/mcp_marker2.py" "$TMP/marker-acc"
cat > "$TMP/cfg-acc/config.dhall" <<DHALL
{ agents =
  [ { name = "fx"
    , agent_type = "agent"
    , mcp_servers = [ { command = "$TMP/mcp_marker2.py", args = [] : List Text } ]
    }
  ]
}
DHALL
"$GATE" --upstream "$TMP/upstream2.sse" --slave-file "$TMP/slave10" \
    --log "$TMP/log-acc.jsonl" --dump-requests "$TMP/dump-acc.jsonl" \
    --deny fx_write --turns 2 2> "$TMP/proxy10.err" &
PROXY10=$!
PROXIES="$PROXIES $PROXY10"
wait_for_slave "$TMP/slave10" "$PROXY10" "$TMP/proxy10.err"
DEV10=$(cat "$TMP/slave10")
out=$(FX_CHARDEV="$DEV10" FX_AGENT_CONFIG_DIR="$TMP/cfg-acc" \
    FX_AGENT_DATA="$TMP/data-acc" HOME="$TMP" \
    "$BIN" -p "$SENTINEL" --agent fx --max-turns 2 --output text)
rc=$?
[ "$rc" -eq 0 ] || { sed -n '1,10p' "$TMP/proxy10.err" >&2; fail "phase 12: accepted-arm run rc=$rc"; }
wait_for_proxy_exit "$PROXY10" "$TMP/proxy10.err"
wait "$PROXY10"
prc=$?
[ "$prc" -eq 0 ] || fail "phase 12: the proxy exited rc=$prc"
TR=$(ls "$TMP"/data-acc/sessions/*/messages.jsonl 2>/dev/null)
[ -f "$TR" ] || fail "phase 12: no guest transcript — the run is not the real scenario"
# the call crossed VERBATIM: the TRUE name is the dispatched name
n=$(pyq "$TR" "len([1 for r in rows for tc in (r.get('tool_calls') or []) if tc.get('name')=='get_weather' and tc.get('id')=='$CALLID'])")
[ "$n" -eq 1 ] || fail "phase 12: the allowed call did NOT cross verbatim with its true name — transparency is broken"
n=$(pyq "$TR" "len([1 for r in rows if r.get('role')=='tool' and r.get('tool_call_id')=='$CALLID' and r.get('content')=='stub-ok-weather'])")
[ "$n" -eq 1 ] || fail "phase 12: the stub's result never reached the transcript — the dispatch did not really happen"
# THE MARKER IS PRESENT — the allowed call EXECUTED (the other direction)
[ -f "$TMP/marker-acc" ] \
    || fail "phase 12: the MARKER IS ABSENT for an ALLOWED call — a proxy that denies everything would pass phase 11; this arm exists to catch exactly that"
# the outgoing frame is NOT rewritten: the stub's own result, verbatim
D="$TMP/dump-acc.jsonl"
n=$(pyq "$D" "len([r for r in rows if any(i.get('type')=='function_call' and i.get('call_id')=='$CALLID' and i.get('name')=='get_weather' for i in r.get('input',[]))])")
[ "$n" -ge 1 ] || fail "phase 12: the dumped frame lost the true name — an allowed call must cross with NO rewrite"
n=$(pyq "$D" "len([r for r in rows if any(i.get('type')=='function_call_output' and i.get('call_id')=='$CALLID' and i.get('output')=='stub-ok-weather' for i in r.get('input',[]))])")
[ "$n" -ge 1 ] || fail "phase 12: the dumped frame's output is not the stub's verbatim result — the outbound leg rewrote an ALLOWED call"
n=$(pyq "$D" "len([r for r in rows if any(i.get('type')=='function_call_output' and isinstance(i.get('output'),str) and i['output'].startswith('(denied by host policy:') for i in r.get('input',[]))])")
[ "$n" -eq 0 ] || fail "phase 12: a denial text crossed for a call that was NOT denied — the substitution leaked into an allowed call"
# the policy RAN and said allowed, with null refusal fields
L="$TMP/log-acc.jsonl"
n=$(pyq "$L" "len([r for r in rows if r.get('call_id')=='$CALLID' and r.get('verdict')=='allowed' and r.get('author')=='denylist' and r.get('refusal_name') is None and r.get('reason') is None and r.get('denial_text') is None])")
[ "$n" -eq 2 ] || fail "phase 12: expected 2 verdict=allowed rows with NULL refusal fields, got $n — the armed-policy allowed shape is wrong"
n=$(pyq "$L" "len([1 for r in rows if r.get('type') in ('unjoined-output','echo-anomaly')])")
[ "$n" -eq 0 ] || fail "phase 12: telemetry anomaly rows in a clean accepted run"
echo "   OK accepted: the true name crossed verbatim, the marker IS touched (the call EXECUTED), the outgoing frame is un-rewritten (stub-ok-weather verbatim), the policy said allowed honestly"

echo "== phase 13: P3 PRE-FIX CONTROL — the P2-era proxy forwards verbatim and the stub DISPATCHES"
# build/fx-hostgate-norewrite is THIS source with the enforcement rewrites
# compiled out (FH_MUTANT_NO_REWRITE) while the policy RECORD still runs:
# exactly the P2-era behavior under a P3 flag surface.  On this fixture the
# true name crosses, the guest dispatches, the marker IS present — while
# the log claims verdict denied.  That pair (marker present + log denied)
# is the asymmetry the phase-11 assertions exist to catch.
mkdir -p "$TMP/data-ctl" "$TMP/cfg-ctl"
make_marker_stub "$TMP/mcp_marker3.py" "$TMP/marker-ctl"
cat > "$TMP/cfg-ctl/config.dhall" <<DHALL
{ agents =
  [ { name = "fx"
    , agent_type = "agent"
    , mcp_servers = [ { command = "$TMP/mcp_marker3.py", args = [] : List Text } ]
    }
  ]
}
DHALL
"$GATENRW" --upstream "$TMP/upstream2.sse" --slave-file "$TMP/slave11" \
    --log "$TMP/log-ctl.jsonl" --dump-requests "$TMP/dump-ctl.jsonl" \
    --deny get_weather --turns 2 2> "$TMP/proxy11.err" &
PROXY11=$!
PROXIES="$PROXIES $PROXY11"
wait_for_slave "$TMP/slave11" "$PROXY11" "$TMP/proxy11.err"
DEV11=$(cat "$TMP/slave11")
out=$(FX_CHARDEV="$DEV11" FX_AGENT_CONFIG_DIR="$TMP/cfg-ctl" \
    FX_AGENT_DATA="$TMP/data-ctl" HOME="$TMP" \
    "$BIN" -p "$SENTINEL" --agent fx --max-turns 2 --output text)
rc=$?
[ "$rc" -eq 0 ] || fail "phase 13: control run rc=$rc — the pre-fix failure must be SILENT to the exit status, not a crash"
wait_for_proxy_exit "$PROXY11" "$TMP/proxy11.err"
wait "$PROXY11"
prc=$?
[ "$prc" -eq 0 ] || fail "phase 13: the control proxy exited rc=$prc"
TR=$(ls "$TMP"/data-ctl/sessions/*/messages.jsonl 2>/dev/null)
n=$(pyq "$TR" "len([1 for r in rows for tc in (r.get('tool_calls') or []) if tc.get('name')=='get_weather'])")
[ "$n" -ge 1 ] || fail "phase 13: the control did not forward the true name — it is not the P2-era behavior, the control is vacuous"
[ -f "$TMP/marker-ctl" ] \
    || fail "phase 13: the control's marker is ABSENT — the scenario cannot dispatch even without a gate; phase 11's marker-absence would prove nothing"
L="$TMP/log-ctl.jsonl"
n=$(pyq "$L" "len([r for r in rows if r.get('call_id')=='$CALLID' and r.get('verdict')=='denied'])")
[ "$n" -ge 1 ] || fail "phase 13: the control's log does not claim a denial — it no longer demonstrates 'the log looks protective while the call executed'"
echo "   OK control: rc 0, the log claims denied, yet the TRUE NAME reached the guest and DISPATCHED (marker present) — exactly the silent-allow shape phase 11 catches by content"

echo "== phase 14: P3 COMPLETENESS MUTANT — ONLY the added-event rewrite removed must still DISPATCH (a partial rewriter is an allow)"
# build/fx-hostgate-blindadd is THIS source with FH_MUTANT_NO_ADDED_REWRITE:
# done and completed keep their rewrites, the outbound substitution keeps
# running — only the output_item.added rewrite is gone.  The guest's tool
# accumulator is fed by the added event ALONE (openai_responses.c:146-161),
# so it accumulates the TRUE name and dispatches it: marker PRESENT, log
# denied.  The gate MUST catch this — a rewrite that misses the added event
# is an allow, no matter how complete every other rewrite looks.
mkdir -p "$TMP/data-blind" "$TMP/cfg-blind"
make_marker_stub "$TMP/mcp_marker4.py" "$TMP/marker-blind"
cat > "$TMP/cfg-blind/config.dhall" <<DHALL
{ agents =
  [ { name = "fx"
    , agent_type = "agent"
    , mcp_servers = [ { command = "$TMP/mcp_marker4.py", args = [] : List Text } ]
    }
  ]
}
DHALL
"$GATEADD" --upstream "$TMP/upstream2.sse" --slave-file "$TMP/slave12" \
    --log "$TMP/log-blind.jsonl" --dump-requests "$TMP/dump-blind.jsonl" \
    --deny get_weather --turns 2 2> "$TMP/proxy12.err" &
PROXY12=$!
PROXIES="$PROXIES $PROXY12"
wait_for_slave "$TMP/slave12" "$PROXY12" "$TMP/proxy12.err"
DEV12=$(cat "$TMP/slave12")
out=$(FX_CHARDEV="$DEV12" FX_AGENT_CONFIG_DIR="$TMP/cfg-blind" \
    FX_AGENT_DATA="$TMP/data-blind" HOME="$TMP" \
    "$BIN" -p "$SENTINEL" --agent fx --max-turns 2 --output text)
rc=$?
[ "$rc" -eq 0 ] || fail "phase 14: mutant run rc=$rc — the completeness mutation must be SILENT to the exit status, not a crash"
wait_for_proxy_exit "$PROXY12" "$TMP/proxy12.err"
wait "$PROXY12"
prc=$?
[ "$prc" -eq 0 ] || fail "phase 14: the mutant proxy exited rc=$prc"
# THE HEADLINE: the guest accumulated the TRUE name from the un-rewritten
# added event and DISPATCHED it — while the record claims a denial.
TR=$(ls "$TMP"/data-blind/sessions/*/messages.jsonl 2>/dev/null)
n=$(pyq "$TR" "len([1 for r in rows for tc in (r.get('tool_calls') or []) if tc.get('name')=='get_weather'])")
[ "$n" -ge 1 ] || fail "phase 14: the mutant's transcript does not carry the true name — the mutation did not take (the added event WAS rewritten), the blind is vacuous"
[ -f "$TMP/marker-blind" ] \
    || fail "phase 14: the mutant's marker is ABSENT — the dispatch did not happen; re-check the mutation actually reproduces the silent allow"
L="$TMP/log-blind.jsonl"
n=$(pyq "$L" "len([r for r in rows if r.get('call_id')=='$CALLID' and r.get('verdict')=='denied'])")
[ "$n" -ge 1 ] || fail "phase 14: the mutant's log does not claim a denial — it is not judged on the protective-looking record"
# the rest of the mutant is INTACT (the mutation is exactly the added
# rewrite): the outbound substitution still fires, so the dump still shows
# the restored name + denial text — proving the dispatch came through the
# decode leg's added event, not through a broken policy or a broken map.
D="$TMP/dump-blind.jsonl"
n=$(pyq "$D" "len([r for r in rows if any(i.get('type')=='function_call_output' and i.get('call_id')=='$CALLID' and isinstance(i.get('output'),str) and i['output'].startswith('(denied by host policy:') for i in r.get('input',[]))])")
[ "$n" -ge 1 ] || fail "phase 14: the mutant's outbound substitution did not fire — the mutation is broader than 'only the added rewrite' and the blind no longer isolates the completeness property"
# and the telemetry ALSO saw it: a denied call whose guest output is not a
# known sentinel (the stub really ran) is an echo-anomaly row
n=$(pyq "$L" "len([1 for r in rows if r.get('type')=='echo-anomaly' and r.get('call_id')=='$CALLID'])")
[ "$n" -ge 1 ] || fail "phase 14: no echo-anomaly row for the denied-but-dispatched call — the telemetry instrument missed what the marker caught"
echo "   OK completeness mutant caught: rc 0, log claims denied, dump still substituted — yet the TRUE NAME reached the accumulator through the un-rewritten added event and DISPATCHED (marker present). The phase-11 assertions flip to a fail on exactly this fixture"

# ── P3-fix: multi-call coverage (the gate had ZERO before this) ──────────────
#
# drive_multi <gate> <fixture> <deny> <tag> — start the gate, run TWO guest
# turns through it against a two-verb stub, reap.  Leaves the log/dump at
# $TMP/multi-$tag/{log,dump}.jsonl, the transcript path in MU_TR, the markers
# at $TMP/multi-$tag/marker-{get_weather,fx_write} and the dir in MU_DIR.
drive_multi() {
    local gate="$1" fixture="$2" deny="$3" tag="$4"
    local d="$TMP/multi-$tag"
    mkdir -p "$d/cfg" "$d/data"
    make_multi_stub "$d/mcp.py" "$d/marker-get_weather" "$d/marker-fx_write"
    cat > "$d/cfg/config.dhall" <<DHALL
{ agents = [ { name = "fx", agent_type = "agent", mcp_servers = [ { command = "$d/mcp.py", args = [] : List Text } ] } ] }
DHALL
    "$gate" --upstream "$fixture" --slave-file "$d/slave" \
        --log "$d/log.jsonl" --dump-requests "$d/dump.jsonl" \
        --deny "$deny" --turns 2 2> "$d/proxy.err" &
    local p=$!
    PROXIES="$PROXIES $p"
    wait_for_slave "$d/slave" "$p" "$d/proxy.err"
    local dev
    dev=$(cat "$d/slave")
    local out rc
    out=$(FX_CHARDEV="$dev" FX_AGENT_CONFIG_DIR="$d/cfg" \
        FX_AGENT_DATA="$d/data" HOME="$TMP" \
        "$BIN" -p "$SENTINEL" --agent fx --max-turns 2 --output text)
    rc=$?
    [ "$rc" -eq 0 ] || { sed -n '1,10p' "$d/proxy.err" >&2; fail "phase $tag: multi-call run rc=$rc"; }
    wait_for_proxy_exit "$p" "$d/proxy.err"
    wait "$p"
    local prc=$?
    [ "$prc" -eq 0 ] || fail "phase $tag: the proxy exited rc=$prc"
    MU_DIR="$d"
    MU_LOG="$d/log.jsonl"
    MU_DUMP="$d/dump.jsonl"
    MU_TR=$(ls "$d"/data/sessions/*/messages.jsonl 2>/dev/null)
}

echo "== phase 15: P3-fix INTERLEAVED deny-B — the SECOND call is denied; each item judged under ITS OWN identity"
drive_multi "$GATE" "$FIX/responses_interleaved.sse" fx_write 15
[ -f "$MU_TR" ] || fail "phase 15: no guest transcript — the run is not the real scenario"
# THE SILENT ALLOW, FLIPPED: fx_write never executes, get_weather does
[ ! -e "$MU_DIR/marker-fx_write" ] \
    || fail "phase 15: marker-fx_write PRESENT — the DENIED fx_write EXECUTED (the interleave silent allow)"
[ -f "$MU_DIR/marker-get_weather" ] \
    || fail "phase 15: marker-get_weather ABSENT — the ACCEPTED get_weather did NOT execute (over-block)"
# the transcript: the denied call is {fx_host_denied, call_B} with args verbatim;
# the allowed call is {get_weather, call_A}; NO tool_call carries fx_write
n=$(pyq "$MU_TR" "len([1 for r in rows for tc in (r.get('tool_calls') or []) if tc.get('name')=='fx_host_denied' and tc.get('id')=='$CALL_B' and tc.get('arguments')=='{\"path\": \"/tmp/evil\"}'])")
[ "$n" -eq 1 ] || fail "phase 15: the transcript does not carry the DENIED call as {fx_host_denied, $CALL_B} with its args verbatim"
n=$(pyq "$MU_TR" "len([1 for r in rows for tc in (r.get('tool_calls') or []) if tc.get('name')=='get_weather' and tc.get('id')=='$CALL_A' and tc.get('arguments')=='{\"city\": \"Paris\"}'])")
[ "$n" -eq 1 ] || fail "phase 15: the transcript does not carry the ALLOWED call as {get_weather, $CALL_A} with its args"
n=$(pyq "$MU_TR" "len([1 for r in rows for tc in (r.get('tool_calls') or []) if tc.get('name')=='fx_write'])")
[ "$n" -eq 0 ] || fail "phase 15: the TRUE NAME fx_write reached the transcript as a call name — the interleave silent allow survived"
# the log: a denied row for call_B AND an allowed row for call_A, each with ITS OWN args
n=$(pyq "$MU_LOG" "len([r for r in rows if r.get('call_id')=='$CALL_B' and r.get('verdict')=='denied' and r.get('args')=='{\"path\": \"/tmp/evil\"}' and r.get('true_name')=='fx_write'])")
[ "$n" -ge 1 ] || fail "phase 15: no denied row for $CALL_B with its OWN args — B was not judged under its own identity"
n=$(pyq "$MU_LOG" "len([r for r in rows if r.get('call_id')=='$CALL_A' and r.get('verdict')=='allowed' and r.get('args')=='{\"city\": \"Paris\"}' and r.get('true_name')=='get_weather'])")
[ "$n" -ge 1 ] || fail "phase 15: no allowed row for $CALL_A with its OWN args — the mis-joined record survived"
# the outbound leg: the denied call's name is restored, its output is the denial text
D="$MU_DUMP"
n=$(pyq "$D" "len([r for r in rows if any(i.get('type')=='function_call' and i.get('call_id')=='$CALL_B' and i.get('name')=='fx_write' for i in r.get('input',[]))])")
[ "$n" -ge 1 ] || fail "phase 15: no dumped frame carries the RESTORED name fx_write for the denied $CALL_B"
n=$(pyq "$D" "len([r for r in rows if any(i.get('type')=='function_call_output' and i.get('call_id')=='$CALL_B' and isinstance(i.get('output'),str) and i['output'].startswith('(denied by host policy:') for i in r.get('input',[]))])")
[ "$n" -ge 1 ] || fail "phase 15: no dumped frame carries the DENIAL TEXT for $CALL_B"
echo "   OK interleaved deny-B: fx_write never executed (marker absent) while get_weather did; denied row for B + allowed row for A (own args); the outbound leg restored the name"

echo "== phase 16: P3-fix INTERLEAVED deny-B PRE-FIX CONTROL — the single accumulator mis-joins and fx_write EXECUTES"
drive_multi "$GATESI" "$FIX/responses_interleaved.sse" fx_write 16
[ -f "$MU_DIR/marker-fx_write" ] \
    || fail "phase 16: marker-fx_write ABSENT — the single-accumulator control did NOT reproduce the silent allow"
[ ! -e "$MU_DIR/marker-get_weather" ] \
    || fail "phase 16: marker-get_weather PRESENT — get_weather was never dispatched (its added was overwritten by B); the control is not the pre-fix shape"
# the mis-joined record: an allowed row under call_A carrying call_B's args,
# and NO row at all for call_B (it was never judged) — the artifact of the bug
n=$(pyq "$MU_LOG" "len([r for r in rows if r.get('call_id')=='$CALL_A' and r.get('verdict')=='allowed' and r.get('args')=='{\"path\": \"/tmp/evil\"}' and r.get('true_name')=='get_weather'])")
[ "$n" -ge 1 ] || fail "phase 16: no allowed row under $CALL_A carrying $CALL_B's args — the artifact of the bug is absent"
n=$(pyq "$MU_LOG" "len([r for r in rows if r.get('call_id')=='$CALL_B' and 'verdict' in r])")
[ "$n" -eq 0 ] || fail "phase 16: a JUDGED row exists for $CALL_B — it was never judged under the single accumulator (the deny map never gained call_B)"
n=$(pyq "$MU_LOG" "len([r for r in rows if r.get('verdict')=='denied'])")
[ "$n" -eq 0 ] || fail "phase 16: a denied row exists — B was never judged under the single accumulator"
echo "   OK interleave pre-fix control: rc 0, fx_write DISPATCHED (marker present), the log carries an allowed row under call_A with call_B's args and NO row for call_B — the mis-join the per-item fix flips"

echo "== phase 17: P3-fix INTERLEAVED deny-A — the FIRST call is denied; the ACCEPTED fx_write executes and is never rewritten"
drive_multi "$GATE" "$FIX/responses_interleaved.sse" get_weather 17
[ -f "$MU_DIR/marker-fx_write" ] \
    || fail "phase 17: marker-fx_write ABSENT — the ACCEPTED fx_write did NOT execute (the over-block direction)"
[ ! -e "$MU_DIR/marker-get_weather" ] \
    || fail "phase 17: marker-get_weather PRESENT — the DENIED get_weather EXECUTED (a silent allow)"
# the transcript: fx_write crossed with its true name; get_weather is the reserved name
n=$(pyq "$MU_TR" "len([1 for r in rows for tc in (r.get('tool_calls') or []) if tc.get('name')=='fx_write' and tc.get('id')=='$CALL_B'])")
[ "$n" -eq 1 ] || fail "phase 17: the ACCEPTED fx_write did not cross with its true name — the denied-A direction over-blocked it"
n=$(pyq "$MU_TR" "len([1 for r in rows for tc in (r.get('tool_calls') or []) if tc.get('name')=='fx_host_denied' and tc.get('id')=='$CALL_A'])")
[ "$n" -eq 1 ] || fail "phase 17: the DENIED get_weather is not the reserved name in the transcript"
# the outbound leg: the turn-2 frame for call_B carries name=fx_write, NEVER the reserved name
D="$MU_DUMP"
n=$(pyq "$D" "len([r for r in rows if any(i.get('type')=='function_call' and i.get('call_id')=='$CALL_B' and i.get('name')=='fx_write' for i in r.get('input',[]))])")
[ "$n" -ge 1 ] || fail "phase 17: no dumped frame carries name=fx_write for $CALL_B"
n=$(pyq "$D" "len([r for r in rows if any(i.get('type')=='function_call' and i.get('call_id')=='$CALL_B' and i.get('name')=='fx_host_denied' for i in r.get('input',[]))])")
[ "$n" -eq 0 ] || fail "phase 17: the reserved name fx_host_denied reached the model-facing frame for $CALL_B — an ACCEPTED call was rewritten"
echo "   OK interleaved deny-A: fx_write EXECUTED (marker present) while get_weather did not; the turn-2 dump carries name=fx_write for call_B, never the reserved name"

echo "== phase 18: P3-fix INTERLEAVED deny-A PRE-FIX CONTROL — the accepted fx_write is over-blocked and leaks its name as fx_host_denied"
drive_multi "$GATESI" "$FIX/responses_interleaved.sse" get_weather 18
[ ! -e "$MU_DIR/marker-fx_write" ] \
    || fail "phase 18: marker-fx_write PRESENT — the accepted fx_write EXECUTED; the control is not the pre-fix over-block"
[ ! -e "$MU_DIR/marker-get_weather" ] \
    || fail "phase 18: marker-get_weather PRESENT — the denied get_weather executed"
# the reserved-name leak: the turn-2 dump's function_call for call_B carries fx_host_denied
D="$MU_DUMP"
n=$(pyq "$D" "len([r for r in rows if any(i.get('type')=='function_call' and i.get('call_id')=='$CALL_B' and i.get('name')=='fx_host_denied' for i in r.get('input',[]))])")
[ "$n" -ge 1 ] || fail "phase 18: the dump does NOT carry the reserved name for $CALL_B — the pre-fix leak is absent"
echo "   OK interleave deny-A pre-fix control: rc 0, fx_write NEVER executed (over-block), and the dump carries function_call name=fx_host_denied for call_B unrestored — the reserved name reaching the model for a call it made under its true name"

echo "== phase 19: P3-fix SEQUENTIAL two-call — the already-correct shape stays correct (regression pin)"
drive_multi "$GATE" "$FIX/responses_sequential.sse" fx_write 19
[ -f "$MU_DIR/marker-get_weather" ] \
    || fail "phase 19: marker-get_weather ABSENT — the sequential allowed call did not execute"
[ ! -e "$MU_DIR/marker-fx_write" ] \
    || fail "phase 19: marker-fx_write PRESENT — the sequential denied call executed"
n=$(pyq "$MU_LOG" "len([r for r in rows if r.get('call_id')=='$CALL_B' and r.get('verdict')=='denied' and r.get('args')=='{\"path\": \"/tmp/evil\"}'])")
[ "$n" -ge 1 ] || fail "phase 19: no denied row for $CALL_B with its own args"
n=$(pyq "$MU_LOG" "len([r for r in rows if r.get('call_id')=='$CALL_A' and r.get('verdict')=='allowed' and r.get('args')=='{\"city\": \"Paris\"}'])")
[ "$n" -ge 1 ] || fail "phase 19: no allowed row for $CALL_A with its own args"
echo "   OK sequential: marker-weather present, marker-write absent; denied row for B + allowed row for A (own args) — a future regression to the single accumulator is caught on the simple case too"

echo "== phase 20: P3-fix PENDING-SUBSTITUTION — a denied call whose outbound substitution never fires must produce an anomaly row"
drive_multi "$GATENOS" "$FIX/responses_interleaved.sse" get_weather 20
# the decode gate is INTACT in this mutant (nothing denied executed): fx_write
# (allowed) ran, get_weather (denied) did not — so the blind isolates the outbound leg
[ -f "$MU_DIR/marker-fx_write" ] \
    || fail "phase 20: marker-fx_write ABSENT — the decode gate is broken in the no-substitute mutant; the blind no longer isolates the outbound leg"
[ ! -e "$MU_DIR/marker-get_weather" ] \
    || fail "phase 20: marker-get_weather PRESENT — the denied call executed; the no-substitute mutant is not the outbound-only blind"
# the outbound leg is missing: the dump carries the reserved name UNRESTORED
D="$MU_DUMP"
n=$(pyq "$D" "len([r for r in rows if any(i.get('type')=='function_call' and i.get('call_id')=='$CALL_A' and i.get('name')=='fx_host_denied' for i in r.get('input',[]))])")
[ "$n" -ge 1 ] || fail "phase 20: the dump does not carry the UNRESTORED reserved name for $CALL_A — the substitution mutation did not take"
# THE INSTRUMENT: an unresolved-substitution anomaly row names the denied call_id
L="$MU_LOG"
n=$(pyq "$L" "len([r for r in rows if r.get('type')=='unresolved-substitution' and r.get('call_id')=='$CALL_A' and r.get('true_name')=='get_weather'])")
[ "$n" -ge 1 ] || fail "phase 20: no unresolved-substitution row for $CALL_A — a missed outbound substitution sat silent (the instrument is dead)"
echo "   OK pending-substitution: rc 0, the decode gate held (nothing denied executed) yet the outbound substitution was compiled out — the dump carries the reserved name unrestored, and the log carries an unresolved-substitution anomaly row naming call_A"

echo "== phase 21: P3-fix NICE 5+7 — the unarmed stream is byte-identical to upstream, and response.completed is the LAST event"
# Capture the FULL served stream straight off the slave (one frame, then drain
# to completed plus a short grace so any post-completed tail is caught), and
# assert BOTH the P1 byte-identity property (NICE 5) and the completed-last
# ordering contract (NICE 7 — the guest breaks its read loop on completed).
"$GATE" --upstream "$TMP/upstream.sse" --slave-file "$TMP/slave13" \
    --log "$TMP/log-nice.jsonl" --turns 1 2> "$TMP/proxy13.err" &
PROXY13=$!
PROXIES="$PROXIES $PROXY13"
wait_for_slave "$TMP/slave13" "$PROXY13" "$TMP/proxy13.err"
DEV13=$(cat "$TMP/slave13")
python3 - "$DEV13" "$TMP/captured.sse" <<'PY'
import json, os, select, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_APPEND)
frame = json.dumps({"model": "m", "stream": True,
                    "input": [{"type": "message", "role": "user", "content": "hi"}]})
os.write(fd, f"{len(frame)}\n{frame}".encode())
data = b""
deadline = time.time() + 10
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 1)
    if not r:
        continue
    b = os.read(fd, 65536)
    if not b:
        break
    data += b
    if b"response.completed" in data:
        tail_end = time.time() + 1.0
        while time.time() < tail_end:
            r, _, _ = select.select([fd], [], [], 0.5)
            if not r:
                break
            b = os.read(fd, 65536)
            if not b:
                break
            data += b
        break
os.close(fd)
open(sys.argv[2], "wb").write(data)
PY
wait_for_proxy_exit "$PROXY13" "$TMP/proxy13.err"
wait "$PROXY13"
# NICE 5: the unarmed served stream is BYTE-IDENTICAL to the upstream file
cmp "$TMP/captured.sse" "$TMP/upstream.sse" \
    || fail "phase 21: the unarmed served stream is not byte-identical to upstream — transparency regressed"
# NICE 7: response.completed is the LAST SSE EVENT forwarded (the recorded
# fixture carries APPENDED request frames after completed — the O_RDWR|O_APPEND
# recording artifact — so the assert scopes to chunks that are real SSE events,
# i.e. carry an `event:` line; the guest breaks on completed and never reads the
# trailing raw bytes)
python3 - "$TMP/captured.sse" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
chunks = [e for e in data.split(b"\n\n") if e.strip()]
sse_events = [e for e in chunks if b"event:" in e]
assert sse_events, "no SSE events captured"
assert b"event: response.completed" in sse_events[-1], \
    f"the last SSE event is not response.completed: {sse_events[-1][:120]!r}"
PY
rc=$?
[ "$rc" -eq 0 ] || fail "phase 21: response.completed is not the LAST event forwarded"
echo "   OK nice-5+7: the unarmed stream is byte-identical to upstream, and response.completed is the last event forwarded"

# ── P3-fix3: the three residual fail-opens (function_call events OUTSIDE the
#    added->done window, crossing VERBATIM with a denied name while armed) ────
#
# These are the SAME family the per-item buffers exist to exclude: a denied
# call's TRUE VERB NAME must never cross the chardev as a call name.  Each
# phase asserts the property ON THE SERVED BYTES (a wire-level invariant),
# not just the log.  The streams are generated into $TMP — never the shared
# fixtures dir, and FX_CHARDEV is never pointed at an existing fixture (the
# probe writes its own request frame; the upstream is read-only).

# drive_raw <gate> <upstream> <deny> <tag> — start the gate ARMED, write ONE
# request frame straight down the chardev, drain the served stream to
# response.completed (or EOF/refusal), reap.  Leaves the served bytes at
# $TMP/raw-$tag/cap.sse, stderr at $TMP/raw-$tag/proxy.err, and RAW_RC as the
# proxy's exit status.  No guest runs: the property is the proxy's decode-side
# rendering, which is guest-independent, and the probe is the guest's exact
# accumulator feed shape (one framed request, then a raw read of the served
# stream).
drive_raw() {
    local gate="$1" upstream="$2" deny="$3" tag="$4"
    local d="$TMP/raw-$tag"
    mkdir -p "$d"
    "$gate" --upstream "$upstream" --slave-file "$d/slave" \
        --log "$d/log.jsonl" --deny "$deny" --turns 1 2> "$d/proxy.err" &
    local p=$!
    PROXIES="$PROXIES $p"
    wait_for_slave "$d/slave" "$p" "$d/proxy.err"
    local dev
    dev=$(cat "$d/slave")
    python3 - "$dev" "$d/cap.sse" <<'PY'
import json, os, select, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_APPEND)
frame = json.dumps({"model": "m", "stream": True,
                    "input": [{"type": "message", "role": "user", "content": "hi"}]})
os.write(fd, f"{len(frame)}\n{frame}".encode())
data = b""
# 60 s: the OVERSIZE arm's 17.8 MiB drain through the pty was MEASURED at
# 11.4 s here, and a drain abandoned on a short deadline leaves the proxy
# blocked in write() with nobody reading — a proxy "hang" that is the probe's
# fault, not the proxy's.
deadline = time.time() + 60
while time.time() < deadline:
    try:
        r, _, _ = select.select([fd], [], [], 1)
    except OSError:
        break
    if not r:
        continue
    try:
        b = os.read(fd, 65536)
    except OSError:
        break  # master closed (refusal / exit): end of stream
    if not b:
        break
    data += b
    if b"response.completed" in data:
        tail = time.time() + 1.0
        while time.time() < tail:
            try:
                r, _, _ = select.select([fd], [], [], 0.5)
            except OSError:
                break
            if not r:
                break
            try:
                b = os.read(fd, 65536)
            except OSError:
                break
            if not b:
                break
            data += b
        break
try:
    os.close(fd)
except OSError:
    pass
open(sys.argv[2], "wb").write(data)
PY
    wait_for_proxy_exit "$p" "$d/proxy.err"
    wait "$p"
    RAW_RC=$?
    RAW_DIR="$d"
    RAW_CAP="$d/cap.sse"
    RAW_ERR="$d/proxy.err"
}

# the four crafted streams.  Each ends in response.completed (so the probe's
# read loop terminates on the normal paths); the oversize added's data line is
# a SINGLE valid-JSON line padded past FH_FRAME_MAX (16 MiB) — the shape the
# review's repro used.
python3 - "$TMP" <<'PY'
import json, os, sys
d = sys.argv[1]
def sse(events):
    out = ""
    for ev, data in events:
        out += "event: %s\n" % ev
        out += "data: %s\n\n" % data
    return out
def fc(iid, cid, status="in_progress", args=""):
    return {"type": "function_call", "id": iid, "status": status,
            "arguments": args, "call_id": cid, "name": "fx_write"}
def completed(output):
    return json.dumps({"type": "response.completed", "response": {
        "id": "probe", "object": "response", "status": "completed",
        "output": output, "parallel_tool_calls": True, "created_at": 1,
        "completed_at": 2, "model": "m", "usage": None}})

open(os.path.join(d, "raw-open.sse"), "w").write(sse([
    ("response.output_item.added",
     json.dumps({"type": "response.output_item.added",
                 "item": fc("item_OV_1", "call_OV_0001"),
                 "output_index": 1, "sequence_number": 1})),
    ("response.completed",
     completed([fc("item_OV_1", "call_OV_0001")])),
]))

open(os.path.join(d, "raw-doneonly.sse"), "w").write(sse([
    ("response.output_item.done",
     json.dumps({"type": "response.output_item.done",
                 "item": fc("item_NE_1", "call_NE_0001", "completed", "{}"),
                 "output_index": 1, "sequence_number": 1})),
    ("response.completed", completed([])),
]))

open(os.path.join(d, "raw-dupdone.sse"), "w").write(sse([
    ("response.output_item.added",
     json.dumps({"type": "response.output_item.added",
                 "item": fc("item_DU_1", "call_DU_0001"),
                 "output_index": 1, "sequence_number": 1})),
    ("response.output_item.done",
     json.dumps({"type": "response.output_item.done",
                 "item": fc("item_DU_1", "call_DU_0001", "completed", "{}"),
                 "output_index": 1, "sequence_number": 2})),
    ("response.output_item.done",
     json.dumps({"type": "response.output_item.done",
                 "item": fc("item_DU_1", "call_DU_0001", "completed", "{}"),
                 "output_index": 1, "sequence_number": 3})),
    ("response.completed", completed([])),
]))

pad = "x" * (17 * 1024 * 1024)
open(os.path.join(d, "raw-oversize.sse"), "w").write(sse([
    ("response.output_item.added",
     json.dumps({"type": "response.output_item.added",
                 "item": fc("item_OS_1", "call_OS_0001"),
                 "padding": pad})),
    ("response.completed", completed([])),
]))
PY

echo "== phase 22: P3-fix3 OPEN-AT-COMPLETED — a still-open denied item's name in completed's output array must NOT cross"
drive_raw "$GATE" "$TMP/raw-open.sse" fx_write 22
[ "$RAW_RC" -eq 0 ] || fail "phase 22: the proxy exited rc=$RAW_RC"
grep -q "STILL OPEN when completed arrived" "$RAW_ERR" \
    || fail "phase 22: no 'STILL OPEN when completed' note — the array rewrite is silent"
python3 - "$RAW_CAP" <<'PY'
import json, sys
data = open(sys.argv[1], "rb").read()
chunks = [c for c in data.split(b"\n\n") if c.strip()]
comp = [c for c in chunks if b"event: response.completed" in c]
assert comp, "no completed event served"
payload = b""
for ln in comp[0].split(b"\n"):
    if ln.startswith(b"data: "):
        payload += ln[6:]
    elif ln.startswith(b"data:"):
        payload += ln[5:]
obj = json.loads(payload)
names = [it.get("name") for it in obj["response"]["output"]
         if it.get("type") == "function_call"]
assert names, "no function_call items in completed's output array"
assert all(n == "fx_host_denied" for n in names), \
    f"the true name crossed in completed's output array: {names}"
PY
rc=$?
[ "$rc" -eq 0 ] || fail "phase 22: completed's output array still carries the denied name on the SERVED BYTES"
echo "   OK open-at-completed: completed's output array carries fx_host_denied (fx_write never crossed in the array), and the 'STILL OPEN' note is loud"

echo "== phase 23: P3-fix3 NEVER-OPENED done — a denied done with no added must NOT cross verbatim"
drive_raw "$GATE" "$TMP/raw-doneonly.sse" fx_write 23
[ "$RAW_RC" -eq 0 ] || fail "phase 23: the proxy exited rc=$RAW_RC"
grep -q "done for an item with NO open buffer carries a DENIED name" "$RAW_ERR" \
    || fail "phase 23: no denied done note — the rewrite is silent"
! grep -q "fx_write" "$RAW_CAP" \
    || fail "phase 23: fx_write crossed the SERVED BYTES on a never-opened done"
grep -q "fx_host_denied" "$RAW_CAP" \
    || fail "phase 23: the reserved name never reached the served done event"
echo "   OK never-opened done: the denied done is rewritten to fx_host_denied on the wire, loudly noted"

echo "== phase 24: P3-fix3 DUPLICATE done — the duplicate after judgement must NOT cross verbatim"
drive_raw "$GATE" "$TMP/raw-dupdone.sse" fx_write 24
[ "$RAW_RC" -eq 0 ] || fail "phase 24: the proxy exited rc=$RAW_RC"
grep -q "done for an item with NO open buffer carries a DENIED name" "$RAW_ERR" \
    || fail "phase 24: no duplicate-done note — the second done's rewrite is silent"
! grep -q "fx_write" "$RAW_CAP" \
    || fail "phase 24: fx_write crossed the SERVED BYTES on a duplicate done"
n=$(grep -o "fx_host_denied" "$RAW_CAP" | wc -l | tr -d ' ')
[ "$n" -eq 3 ] || fail "phase 24: expected the reserved name 3 times (added + done + duplicate done), got $n"
echo "   OK duplicate done: added + done + duplicate done all carry fx_host_denied; the true name never crossed"

echo "== phase 25: P3-fix3 OVERSIZE added — the armed proxy REFUSES (fail-closed), the pinned pre-fix control forwards"
# the FIXED gate: an armed, >16MiB added cannot be judged, so the stream is
# refused and nothing crosses.
drive_raw "$GATE" "$TMP/raw-oversize.sse" fx_write 25
[ "$RAW_RC" -ne 0 ] || fail "phase 25: the armed proxy did NOT refuse the over-cap stream (rc=$RAW_RC)"
grep -q "REFUSING the stream" "$RAW_ERR" \
    || fail "phase 25: the refusal note is absent"
[ ! -s "$RAW_CAP" ] || fail "phase 25: the refused stream still served bytes"
echo "   OK oversize fail-closed: armed proxy rc=$RAW_RC, served 0 bytes, 'REFUSING the stream' note present"
# the PINNED PRE-FIX CONTROL (the single-item legacy accumulator, which kept
# the old oversize fail-open): the same 17MiB added crosses verbatim with the
# false 'event skipped' note — the asymmetry the fix flips.
drive_raw "$GATESI" "$TMP/raw-oversize.sse" fx_write 25ctl
[ "$RAW_RC" -eq 0 ] || fail "phase 25: the pre-fix control exited rc=$RAW_RC"
grep -q "event skipped" "$RAW_ERR" \
    || fail "phase 25: the pre-fix control lost the false 'event skipped' note — it is no longer the pinned before"
grep -q "fx_write" "$RAW_CAP" \
    || fail "phase 25: the pre-fix control did NOT forward the denied name — the asymmetry arm is empty"
echo "   OK oversize asymmetry: fixed arm refuses (0 bytes), pinned pre-fix control forwards fx_write verbatim under a false 'event skipped' note"

# ── P4: THE RESERVED-NAME CONTRACT ─────────────────────────────────────────
#
# P3 USED the reserved name; P4 makes its soundness CHECKED, and the DIRECTION
# is what shapes every arm below: a reserved name that collides with a catalog
# verb is CALLABLE (an allow-all lane dispatches it and the verbs server
# answers) = a SILENT ALLOW.  A startup refusal is the only place that can be
# loud, so each refusal arm is paired with a build of the SAME SOURCE in which
# the check is absent and the proxy STARTS — the asymmetry is the proof, and
# the collision arm measures the silent allow END TO END (marker + transcript),
# not by argument.

# ── P4/P5 helpers ───────────────────────────────────────────────────────────

# make_args_stub <script> <marker> — the dispatch-recording stub for the
# JUSTIFIED arm: for the KNOWN verb it records the RAW arguments it was handed
# (the instrument for "the justification rode with the call, THROUGH the guest,
# into the verb") and answers; anything else gets -32602 exactly as the real
# verbs server refuses an unknown name (fx-verbs-server.c:2669-2674).
make_args_stub() { # <script-path> <marker-path>
    cat > "$1" <<PY
#!/usr/bin/env python3
# Records the arguments it RECEIVES, then answers — the riding key's witness.
import json
import sys

MARKER = "$2"
KNOWN = "get_weather"

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        req = json.loads(line)
    except ValueError:
        continue
    m = req.get("method")
    if m == "initialize":
        print(json.dumps({"jsonrpc": "2.0", "id": req.get("id"), "result": {
            "protocolVersion": req.get("params", {}).get("protocolVersion"),
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "hostgate-args-stub", "version": "0"}}}),
            flush=True)
    elif m == "tools/call":
        name = (req.get("params") or {}).get("name")
        if name == KNOWN:
            args = (req.get("params") or {}).get("arguments")
            with open(MARKER, "a") as f:
                f.write(json.dumps(args, sort_keys=True) + "\\n")
            print(json.dumps({"jsonrpc": "2.0", "id": req.get("id"),
                              "result": {"content": [{"type": "text",
                                                      "text": "stub-ok-weather"}]}}),
                  flush=True)
        else:
            print(json.dumps({"jsonrpc": "2.0", "id": req.get("id"),
                              "error": {"code": -32602,
                                        "message": "unknown tool: %s" % name}}),
                  flush=True)
PY
    chmod +x "$1"
}

# proxy_roundtrip <gate> <upstream> <tag> [extra argv...] — start ONE gate
# (bounded to a single turn), drive ONE request frame straight down the chardev,
# drain the served stream, reap.  Leaves RT_RC (the gate's exit status), RT_CAP
# (the SERVED bytes), RT_ERR (stderr), RT_LOG (the one log) and RT_DUMP (the
# rewritten model-facing frame) for the caller.  No guest runs: the properties
# asserted through it are the proxy's own (what it serves, what it records,
# what it would forward), and each crafted stream is the guest's exact
# accumulator shape.  The upstream is only ever READ — the probe writes its own
# request frame, so FX_CHARDEV is never pointed at a fixture.
proxy_roundtrip() {
    local gate="$1" upstream="$2" tag="$3"
    shift 3
    local d="$TMP/rt-$tag"
    mkdir -p "$d"
    "$gate" --upstream "$upstream" --slave-file "$d/slave" --log "$d/log.jsonl" \
        --dump-requests "$d/dump.jsonl" "$@" --turns 1 2> "$d/proxy.err" &
    local p=$!
    PROXIES="$PROXIES $p"
    wait_for_slave "$d/slave" "$p" "$d/proxy.err"
    local dev
    dev=$(cat "$d/slave")
    python3 - "$dev" "$d/cap.sse" <<'PY'
import json, os, select, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_APPEND)
frame = json.dumps({"model": "m", "stream": True,
                    "input": [{"type": "message", "role": "user", "content": "hi"}]})
os.write(fd, f"{len(frame)}\n{frame}".encode())
data = b""
# 60 s: the OVERSIZE arm's 17.8 MiB drain through the pty was MEASURED at
# 11.4 s here, and a drain abandoned on a short deadline leaves the proxy
# blocked in write() with nobody reading — a proxy "hang" that is the probe's
# fault, not the proxy's.
deadline = time.time() + 60
while time.time() < deadline:
    try:
        r, _, _ = select.select([fd], [], [], 1)
    except OSError:
        break
    if not r:
        continue
    try:
        b = os.read(fd, 65536)
    except OSError:
        break  # master closed (refusal / exit): end of stream
    if not b:
        break
    data += b
    if b"response.completed" in data:
        tail = time.time() + 1.0
        while time.time() < tail:
            try:
                r, _, _ = select.select([fd], [], [], 0.5)
            except OSError:
                break
            if not r:
                break
            try:
                b = os.read(fd, 65536)
            except OSError:
                break
            if not b:
                break
            data += b
        break
try:
    os.close(fd)
except OSError:
    pass
open(sys.argv[2], "wb").write(data)
PY
    wait_for_proxy_exit "$p" "$d/proxy.err"
    wait "$p"
    RT_RC=$?
    RT_DIR="$d"
    RT_CAP="$d/cap.sse"
    RT_ERR="$d/proxy.err"
    RT_LOG="$d/log.jsonl"
    RT_DUMP="$d/dump.jsonl"
}

echo "== phase 26: P4 CATALOG PROVENANCE — the pinned mirror must equal the real VERBS[] table"
# The gate's INDEPENDENT copy of the ground truth: the VERBS[] table in the
# verbs server's own source (the proxy cannot read it at run time, and the
# pinned list is only as good as the bytes it pins).  A verb added THERE
# without re-pinning the proxy surfaces here, before it can become a silent
# collision later.
awk '/^static const Verb VERBS\[\] = \{/,/^\};/' "$ROOT/tools/fx-verbs-server.c" \
    | grep -o '^    { "fx_[a-z_]*"' | sed 's/.*"\(fx_[a-z_]*\)"/\1/' > "$TMP/verbs-real.txt"
nreal=$(wc -l < "$TMP/verbs-real.txt" | tr -d ' ')
[ "$nreal" -ge 10 ] || fail "phase 26: extracted only $nreal verb(s) from tools/fx-verbs-server.c — the provenance check is not reading the table, so a pass here would be vacuous"
"$GATE" --print-catalog > "$TMP/verbs-pinned.txt" || fail "phase 26: --print-catalog failed"
if ! diff -u "$TMP/verbs-real.txt" "$TMP/verbs-pinned.txt" > "$TMP/verbs-drift.diff"; then
    sed -n '1,14p' "$TMP/verbs-drift.diff" >&2
    fail "phase 26: the proxy's pinned catalog DRIFTED from the VERBS[] table in tools/fx-verbs-server.c ($nreal verb(s) there) — the collision check would be checking a stale list"
fi
# THE PIN, restated in the gate as well: the proxy verifies this sha256 at
# startup, and an edit to the catalog text without a re-pin now fails in TWO
# places (the proxy refuses to start, and this constant).
CATALOG_SHA_EXPECTED="6b97a08255734cfb5cead2e347a0197ce7582fd02d74b2a2e92327b74496bf7a"
got=$("$GATE" --print-catalog-sha) || fail "phase 26: --print-catalog-sha failed"
[ "$got" = "$CATALOG_SHA_EXPECTED" ] || fail "phase 26: the pinned catalog sha256 is $got, the gate expects $CATALOG_SHA_EXPECTED — the catalog was edited without re-pinning the gate"
sha=$(sha256sum "$TMP/verbs-pinned.txt" | cut -d' ' -f1)
[ "$sha" = "$CATALOG_SHA_EXPECTED" ] || fail "phase 26: sha256 of the printed catalog is $sha — the pin does not describe the printed bytes"
# ... and the RESERVED NAME against the guest's own rule (src/runner.c:49-70),
# asserted on the REAL build's startup contract line (phase 2's proxy ran it).
grep -q 'P4 name contract: reserved name "fx_host_denied" passes' "$TMP/proxy1.err" \
    || fail "phase 26: the real build printed no P4 name-contract line — the check did not run at startup"
grep -q "collides with none of the $nreal pinned catalog verb(s)" "$TMP/proxy1.err" \
    || fail "phase 26: the contract line does not name $nreal catalog verbs — the count it checked is not the table's"
python3 - "$GATE" <<'PY'
import re, subprocess, sys
sha = subprocess.run([sys.argv[1], "--print-catalog-sha"], capture_output=True, text=True).stdout.strip()
catalog = subprocess.run([sys.argv[1], "--print-catalog"], capture_output=True, text=True).stdout.split()
assert len(catalog) == 13, catalog
assert "fx_host_denied" not in catalog, "the reserved name IS a catalog verb"
# the guest's rule, restated from src/runner.c:49-70: ^[A-Za-z0-9._-]+$, not '-'
assert re.fullmatch(r"[A-Za-z0-9._-]+", "fx_host_denied"), "charset"
assert not "fx_host_denied".startswith("-")
assert re.fullmatch(r"[0-9a-f]{64}", sha), sha
PY
rc=$?
[ "$rc" -eq 0 ] || fail "phase 26: the reserved name / catalog / pin properties do not hold (rc=$rc)"
echo "   OK provenance: --print-catalog == the VERBS[] table in tools/fx-verbs-server.c ($nreal verbs, byte-identical), the pin describes those bytes, and fx_host_denied is no verb while passing the guest's charset"

echo "== phase 27: P4 STARTUP REFUSALS — collision / unparseable name / stale pin, all LOUD and EARLY"
# Every arm runs the real proxy with an override that makes the contract
# FAIL, bounded by `timeout` (a build that fails to refuse would block on the
# chardev forever — the gate must still end), and asserts the refusal happens
# BEFORE the slave path is published: after that point the proxy is serving,
# and a silent allow has already begun.
refuse_arm() { # <bin> <tag> <stderr-substring-that-must-appear>
    local bin="$1" tag="$2" want="$3"
    # a separate statement: bash expands every word of a `local` declaration
    # before assigning any of them, so `d="$TMP/p4-$tag"` in the SAME line is
    # an unbound-variable error under `set -u`
    local d="$TMP/p4-$tag"
    mkdir -p "$d"
    timeout 10 "$bin" --upstream "$TMP/upstream2.sse" --slave-file "$d/slave" \
        --log "$d/log.jsonl" --turns 1 2> "$d/err"
    local rc=$?
    [ "$rc" -ne 0 ] || fail "phase 27 ($tag): the proxy STARTED (rc=$rc) — the refusal did not fire and the collision went live"
    [ ! -e "$d/slave" ] || fail "phase 27 ($tag): the slave path was published BEFORE the refusal — a refusal that happens after serving is not early enough to be a gate"
    grep -q "$want" "$d/err" || { sed -n '1,6p' "$d/err" >&2; fail "phase 27 ($tag): the refusal does not name its cause ('$want')"; }
    echo "   OK p4-$tag: rc=$rc, no slave path published, stderr names the cause"
}
refuse_arm "$GATECOLLIDE" collide "COLLIDES with catalog verb \"fx_write\""
refuse_arm "$GATEBADNAME" badname "does NOT match the guest"
refuse_arm "$GATEBADPIN" badpin "compiled pin is 0000"

echo "== phase 28: P4 COLLISION = SILENT ALLOW — the asymmetry, measured end to end"
# build/fx-hostgate-nonamecheck is the SAME SOURCE with the contract compiled
# out AND the reserved name overridden to the catalog verb fx_write: exactly
# the collision the real build refuses at startup (phase 27).  This build
# STARTS, and because the lane declares NO tool lists — ALLOW-ALL
# (tool_policy.c:85-97) — the guest DISPATCHES the colliding "reserved" name
# and the servers answer.  THAT is the silent allow, and the assertions are the
# marker (it executed), the transcript (under which name), and the log (which
# claims a denial while it happened).
mkdir -p "$TMP/data-collide" "$TMP/cfg-collide"
make_multi_stub "$TMP/mcp_multi28.py" "$TMP/marker28-weather" "$TMP/marker28-write"
cat > "$TMP/cfg-collide/config.dhall" <<DHALL
{ agents =
  [ { name = "fx"
    , agent_type = "agent"
    , mcp_servers = [ { command = "$TMP/mcp_multi28.py", args = [] : List Text } ]
    }
  ]
}
DHALL
# the ALLOW-ALL property is asserted, not assumed: no tool list anywhere in
# this lane's config (a config that DID list fx_host_denied would refuse the
# call in the guest and the arm would prove nothing about the collision).
grep -q 'enabled_tools\|disabled_tools' "$TMP/cfg-collide/config.dhall" \
    && fail "phase 28: the lane declares a tool list — it is not the ALLOW-ALL lane this arm is about"
"$GATENONAME" --upstream "$TMP/upstream2.sse" --slave-file "$TMP/slave28" \
    --log "$TMP/log-collide28.jsonl" --deny get_weather --turns 2 2> "$TMP/proxy28.err" &
PROXY28=$!
PROXIES="$PROXIES $PROXY28"
wait_for_slave "$TMP/slave28" "$PROXY28" "$TMP/proxy28.err"
DEV28=$(cat "$TMP/slave28")
out=$(FX_CHARDEV="$DEV28" FX_AGENT_CONFIG_DIR="$TMP/cfg-collide" \
    FX_AGENT_DATA="$TMP/data-collide" HOME="$TMP" \
    "$BIN" -p "$SENTINEL" --agent fx --max-turns 2 --output text)
rc=$?
[ "$rc" -eq 0 ] || { sed -n '1,10p' "$TMP/proxy28.err" >&2; fail "phase 28: the no-contract run rc=$rc (the mutant must have started AND served)"; }
wait_for_proxy_exit "$PROXY28" "$TMP/proxy28.err"
grep -q 'COMPILED OUT (FH_MUTANT_NO_NAME_CONTRACT)' "$TMP/proxy28.err" \
    || fail "phase 28: the build did not say the contract is compiled out — it is not the mutant this arm needs"
grep -q 'authors armed' "$TMP/proxy28.err" || fail "phase 28: the proxy never reached its startup honesty lines (the refusal path, not the mutant, ran)"
[ -f "$TMP/marker28-write" ] \
    || fail "phase 28: the colliding reserved name fx_write did NOT execute — the arm did not reproduce the silent allow and proves nothing"
[ ! -e "$TMP/marker28-weather" ] \
    || fail "phase 28: the model's true call get_weather executed — the deny never fired (wrong arm)"
TR=$(ls "$TMP"/data-collide/sessions/*/messages.jsonl 2>/dev/null)
[ -f "$TR" ] || fail "phase 28: no guest transcript"
n=$(pyq "$TR" "len([1 for r in rows for tc in (r.get('tool_calls') or []) if tc.get('name')=='fx_write'])")
[ "$n" -ge 1 ] || fail "phase 28: the guest never dispatched the colliding name — nothing crossed"
n=$(pyq "$TR" "len([1 for r in rows for tc in (r.get('tool_calls') or []) if tc.get('name')=='get_weather'])")
[ "$n" -eq 0 ] || fail "phase 28: get_weather reached the accumulator — this is not the rewritten path"
n=$(pyq "$TMP/log-collide28.jsonl" "len([r for r in rows if r.get('verdict')=='denied' and r.get('refusal_name')=='denied-by-denylist'])")
[ "$n" -ge 1 ] || fail "phase 28: the log does not claim the denial — the arm is not 'the record looks protective while the colliding name executes'"
echo "   OK collision asymmetry: the real build REFUSES (phase 27) while this one starts, the ALLOW-ALL lane dispatches the colliding fx_write (marker PRESENT), and the log claims denied — the silent allow, reproduced"
# the UNPARSEABLE-name control: same mutant, the reserved name overridden to a
# string the guest's validate_identifier rejects.  The real build refuses at
# startup (phase 27); this build STARTS and publishes its slave path — i.e. the
# startup refusal is the ONLY thing standing between that name and the wire.
mkdir -p "$TMP/p4-charsetctl"
"$GATENONAMEBAD" --upstream "$TMP/upstream2.sse" --slave-file "$TMP/p4-charsetctl/slave" \
    --log "$TMP/p4-charsetctl/log.jsonl" --turns 1 2> "$TMP/p4-charsetctl/err" &
PROXY28B=$!
PROXIES="$PROXIES $PROXY28B"
wait_for_slave "$TMP/p4-charsetctl/slave" "$PROXY28B" "$TMP/p4-charsetctl/err"
kill "$PROXY28B" 2>/dev/null
wait "$PROXY28B" 2>/dev/null
echo "   OK charset asymmetry: with the check compiled out the unparseable reserved name goes LIVE (slave published) where the real build refuses"

echo "== phase 29: P5 THE HOST INJECTS THE tools ARRAY (and the model being kept in ignorance is a mutant)"
# The design property: the justification RIDES WITH THE CALL — which only works
# if the model is TOLD to send one.  The guest sends NO tools array (MEASURED,
# agent_loop.c:68-69), so the host owns it; --require-justification makes the
# forwarded frame carry the pinned catalog with `justification` REQUIRED.
# Asserted on the DUMPED frame (the object the proxy would send), and paired
# with the injection compiled out: the same flag then denies calls the model
# was never told to justify.
proxy_roundtrip "$GATE" "$TMP/upstream2.sse" inject --require-justification --deny fx_write
[ "$RT_RC" -eq 0 ] || fail "phase 29: the injection run exited rc=$RT_RC"
python3 - "$RT_DUMP" "$TMP/verbs-pinned.txt" <<'PY'
import json, sys
frames = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert frames, "no dumped frame"
verbs = [v.strip() for v in open(sys.argv[2]) if v.strip()]
f = frames[0]
assert "tools" in f, "the forwarded frame carries NO tools array — the model is never told"
tools = f["tools"]
names = [t.get("name") for t in tools]
assert names == verbs, f"the injected catalog != the pinned one: {names} vs {verbs}"
for t in tools:
    p = t["parameters"]
    assert p["required"] == ["justification"], (t["name"], p.get("required"))
    assert p["properties"]["justification"]["type"] == "string", t["name"]
    assert t["type"] == "function"
print(f"injected catalog: {len(tools)} tool(s), each requiring a string justification")
PY
rc=$?
[ "$rc" -eq 0 ] || fail "phase 29: the forwarded request does not carry the pinned catalog with justification REQUIRED (rc=$rc)"
proxy_roundtrip "$GATENOTOOLS" "$TMP/upstream2.sse" notools --require-justification
[ "$RT_RC" -eq 0 ] || fail "phase 29: the no-injection control exited rc=$RT_RC"
grep -q 'tools-array injection COMPILED OUT' "$RT_ERR" \
    || fail "phase 29: the no-injection build did not say the injection is compiled out"
n=$(pyq "$RT_DUMP" "len([1 for r in rows if 'tools' in r])")
[ "$n" -eq 0 ] || fail "phase 29: the no-injection build STILL sent a tools array — the control is vacuous"
n=$(pyq "$RT_LOG" "len([r for r in rows if r.get('verdict')=='denied' and r.get('refusal_name')=='absent-justification'])")
[ "$n" -ge 1 ] || fail "phase 29: the no-injection build did not deny the unjustified call — the dead-agent shape needs BOTH halves (a check the model was never told about)"
echo "   OK injection: the forwarded frame carries all 13 pinned verbs with justification REQUIRED, and the injection-compiled-out build sends none while still denying — the check the model was never told about"

echo "== phase 30: P5 JUSTIFIED — the claim rides THROUGH the guest into the verb (zero guest change)"
# responses_justified.sse is responses_tool.sse with the call's arguments
# carrying a justification — delivered the way a REAL provider delivers
# arguments: `arguments:""` in the added event, every byte in the DELTAS.  The
# arm is end-to-end: the proxy must allow it (judging the accumulator the guest
# will dispatch), the guest must dispatch it UNCHANGED, and the verb must
# receive the justification RIDING WITH THE CALL — which is what makes the
# front half of the claim (the model says why) real, and is also the evidence
# that nothing needs stripping.
mkdir -p "$TMP/data-just" "$TMP/cfg-just"
cp "$FIX/responses_justified.sse" "$TMP/upstream-just.sse"
make_args_stub "$TMP/mcp_args30.py" "$TMP/marker30"
cat > "$TMP/cfg-just/config.dhall" <<DHALL
{ agents =
  [ { name = "fx"
    , agent_type = "agent"
    , mcp_servers = [ { command = "$TMP/mcp_args30.py", args = [] : List Text } ]
    }
  ]
}
DHALL
"$GATE" --upstream "$TMP/upstream-just.sse" --slave-file "$TMP/slave30" \
    --log "$TMP/log-just30.jsonl" --dump-requests "$TMP/dump-just30.jsonl" \
    --require-justification --deny fx_write --turns 2 2> "$TMP/proxy30.err" &
PROXY30=$!
PROXIES="$PROXIES $PROXY30"
wait_for_slave "$TMP/slave30" "$PROXY30" "$TMP/proxy30.err"
DEV30=$(cat "$TMP/slave30")
out=$(FX_CHARDEV="$DEV30" FX_AGENT_CONFIG_DIR="$TMP/cfg-just" \
    FX_AGENT_DATA="$TMP/data-just" HOME="$TMP" \
    "$BIN" -p "$SENTINEL" --agent fx --max-turns 2 --output text)
rc=$?
[ "$rc" -eq 0 ] || { sed -n '1,12p' "$TMP/proxy30.err" >&2; fail "phase 30: the justified run rc=$rc"; }
wait_for_proxy_exit "$PROXY30" "$TMP/proxy30.err"
wait "$PROXY30"
prc=$?
[ "$prc" -eq 0 ] || fail "phase 30: the proxy exited rc=$prc"
[ -f "$TMP/marker30" ] || fail "phase 30: the marker is ABSENT — a call WITH a valid justification did not execute (the check denies honest calls)"
grep -q '"justification"' "$TMP/marker30" \
    || { cat "$TMP/marker30" >&2; fail "phase 30: the verb received no justification — the claim did not ride with the call through the guest"; }
grep -q '"city"' "$TMP/marker30" || fail "phase 30: the verb did not receive the call's own arguments"
TR=$(ls "$TMP"/data-just/sessions/*/messages.jsonl 2>/dev/null)
[ -f "$TR" ] || fail "phase 30: no guest transcript"
n=$(pyq "$TR" "len([1 for r in rows for tc in (r.get('tool_calls') or []) if tc.get('name')=='get_weather'])")
[ "$n" -ge 1 ] || fail "phase 30: the true name did not cross for an ALLOWED call — transparency is broken"
n=$(pyq "$TR" "len([1 for r in rows if r.get('role')=='tool' and r.get('content')=='stub-ok-weather'])")
[ "$n" -ge 1 ] || fail "phase 30: the stub's result never reached the transcript"
n=$(pyq "$TMP/log-just30.jsonl" "len([r for r in rows if r.get('call_id')=='$CALLID' and r.get('verdict')=='allowed' and r.get('author')=='denylist+justification'])")
[ "$n" -ge 1 ] || fail "phase 30: no row records verdict=allowed with BOTH authors that ran (denylist+justification)"
n=$(pyq "$TMP/log-just30.jsonl" "len([1 for r in rows if r.get('type')=='turn-stats' and r.get('allowed')>=1 and r.get('denied')==0])")
[ "$n" -ge 1 ] || fail "phase 30: the denial-rate instrument shows no allowed turn — the positive direction of the instrument is missing"
n=$(pyq "$TMP/dump-just30.jsonl" "len([r for r in rows if any(i.get('type')=='function_call_output' and isinstance(i.get('output'),str) and i['output'].startswith('(denied by host policy:') for i in r.get('input',[]))])")
[ "$n" -eq 0 ] || fail "phase 30: a denial text crossed for a call that was NOT denied"
echo "   OK justified: the call crossed and EXECUTED, and the verb received the call's justification RIDING WITH IT (arguments verbatim through the guest) — zero guest change"

echo "== phase 31: P5 ABSENT JUSTIFICATION — DENIED BY NAME, and the denial reaches the model"
# responses_tool.sse's call carries `{"city": "Paris"}` and no justification:
# under --require-justification the host must refuse it BY NAME, and the TRUE
# NAME must never cross — the P3 invariant, now driven by a refusal the host
# makes for itself.  All the content assertions are the P3 ones, re-pointed.
mkdir -p "$TMP/data-abs" "$TMP/cfg-abs"
make_marker_stub "$TMP/mcp_marker31.py" "$TMP/marker31"
cat > "$TMP/cfg-abs/config.dhall" <<DHALL
{ agents =
  [ { name = "fx"
    , agent_type = "agent"
    , mcp_servers = [ { command = "$TMP/mcp_marker31.py", args = [] : List Text } ]
    }
  ]
}
DHALL
"$GATE" --upstream "$TMP/upstream2.sse" --slave-file "$TMP/slave31" \
    --log "$TMP/log-abs31.jsonl" --dump-requests "$TMP/dump-abs31.jsonl" \
    --require-justification --turns 2 2> "$TMP/proxy31.err" &
PROXY31=$!
PROXIES="$PROXIES $PROXY31"
wait_for_slave "$TMP/slave31" "$PROXY31" "$TMP/proxy31.err"
DEV31=$(cat "$TMP/slave31")
out=$(FX_CHARDEV="$DEV31" FX_AGENT_CONFIG_DIR="$TMP/cfg-abs" \
    FX_AGENT_DATA="$TMP/data-abs" HOME="$TMP" \
    "$BIN" -p "$SENTINEL" --agent fx --max-turns 2 --output text)
rc=$?
[ "$rc" -eq 0 ] || { sed -n '1,12p' "$TMP/proxy31.err" >&2; fail "phase 31: the absent-justification run rc=$rc"; }
wait_for_proxy_exit "$PROXY31" "$TMP/proxy31.err"
wait "$PROXY31"
prc=$?
[ "$prc" -eq 0 ] || fail "phase 31: the proxy exited rc=$prc"
[ ! -e "$TMP/marker31" ] || fail "phase 31: THE MARKER IS PRESENT — an unjustified call EXECUTED (fail-open)"
TR=$(ls "$TMP"/data-abs/sessions/*/messages.jsonl 2>/dev/null)
[ -f "$TR" ] || fail "phase 31: no guest transcript"
n=$(pyq "$TR" "len([1 for r in rows for tc in (r.get('tool_calls') or []) if tc.get('name')=='fx_host_denied' and tc.get('id')=='$CALLID'])")
[ "$n" -eq 1 ] || fail "phase 31: the transcript does not carry the call as the reserved name — the refusal did not take the P3 path"
n=$(pyq "$TR" "len([1 for r in rows for tc in (r.get('tool_calls') or []) if tc.get('name')=='get_weather'])")
[ "$n" -eq 0 ] || fail "phase 31: the TRUE NAME crossed into the guest for a refused call — THE INVARIANT IS BROKEN"
n=$(pyq "$TR" "len([1 for r in rows if r.get('role')=='tool' and r.get('tool_call_id')=='$CALLID' and r.get('content')=='(tool call failed)'])")
[ "$n" -eq 1 ] || fail "phase 31: the guest produced no sentinel for the refused call"
n=$(pyq "$TMP/log-abs31.jsonl" "len([r for r in rows if r.get('call_id')=='$CALLID' and r.get('verdict')=='denied' and r.get('author')=='justification' and r.get('refusal_name')=='absent-justification' and isinstance(r.get('reason'),str) and 'DENIED BY NAME absent-justification' in r['reason']])")
[ "$n" -ge 1 ] || fail "phase 31: no row carries verdict=denied with author=justification and refusal_name=absent-justification"
n=$(pyq "$TMP/dump-abs31.jsonl" "len([r for r in rows if any(i.get('type')=='function_call' and i.get('call_id')=='$CALLID' and i.get('name')=='get_weather' for i in r.get('input',[]))])")
[ "$n" -ge 1 ] || fail "phase 31: the OUTBOUND frame does not restore the true name — the model would see a call it never made (the EXISTING P3 substitution did not run)"
n=$(pyq "$TMP/dump-abs31.jsonl" "len([r for r in rows if any(i.get('type')=='function_call_output' and i.get('call_id')=='$CALLID' and isinstance(i.get('output'),str) and i['output'].startswith('(denied by host policy:') and 'absent-justification' in i['output'] for i in r.get('input',[]))])")
[ "$n" -ge 1 ] || fail "phase 31: the denial text never reached the model as the call's own result"
n=$(pyq "$TMP/dump-abs31.jsonl" "len([1 for r in rows if 'fx_host_denied' in json.dumps(r.get('input',[]))])")
[ "$n" -eq 0 ] || fail "phase 31: the reserved name survived into a model-facing frame"
echo "   OK absent-justification: refused BY NAME through the existing P3 path (reserved name on the wire, nothing dispatched, the true name and the denial text restored on the outbound leg)"

echo "== phase 31b: P5 THE DENIAL-RATE INSTRUMENT — the dead-agent shape is a NUMBER, not an inference"
# THIS is the shape P5 can introduce and no other assertion can see: every call
# denied, nothing executing, every line protective.  The instrument must report
# it — per turn, and for the run — loudly.
grep -q 'DENIAL RATE 100%' "$TMP/proxy31.err" \
    || { grep -n 'call stats' "$TMP/proxy31.err" | head -3 >&2; fail "phase 31b: no 100%-denied line — the dead-agent shape is invisible on stderr"; }
n=$(pyq "$TMP/log-abs31.jsonl" "len([1 for r in rows if r.get('type')=='turn-stats'])")
[ "$n" -ge 1 ] || fail "phase 31b: no turn-stats row — the per-turn rate is missing from the record"
n=$(pyq "$TMP/log-abs31.jsonl" "len([r for r in rows if r.get('type')=='turn-stats' and r.get('calls',0)>0 and r.get('denied')==r.get('calls') and r.get('denial_rate')==1.0 and r.get('denial_reasons',{}).get('absent-justification',0)>=1])")
[ "$n" -ge 1 ] || fail "phase 31b: no turn-stats row reports calls==denied with a denial_rate of 1.0 and the absent-justification reason"
n=$(pyq "$TMP/log-abs31.jsonl" "len([r for r in rows if r.get('type')=='proxy-exit' and r.get('calls_total',0)>0 and r.get('denied_total')==r.get('calls_total') and r.get('all_denied') is True])")
[ "$n" -eq 1 ] || fail "phase 31b: the exit row carries no run aggregate (or does not say all_denied)"
grep -q 'ALL [0-9]* call(s) DENIED' "$TMP/proxy31.err" \
    || fail "phase 31b: the run-level all-denied line is missing"
n=$(pyq "$TMP/log-abs31.jsonl" "len([1 for r in rows if r.get('type')=='turn-stats' and r.get('calls')==0 and r.get('denial_rate') is not None])")
[ "$n" -eq 0 ] || fail "phase 31b: a call-free turn reports a denial_rate — a rate over an empty sample is a claim, not a measurement"
echo "   OK instrument: per-turn turn-stats (calls/denied/allowed/rate/reasons) + the run aggregate + the loud 100%-denied and ALL-DENIED lines all report the dead-agent shape"

echo "== phase 32: P5 MALFORMED JUSTIFICATION — denied by name, for each malformed shape"
# The malformed class, on crafted streams (generated into $TMP — never the
# shared fixtures): a justification that is not a string, one that is blank,
# and arguments that are not an object at all.  Each must be refused BY NAME
# and must not let the true name cross.  The streams are the guest's exact
# accumulator shape (`arguments:""` in added, every byte in the DELTAS), so
# what is judged is what the guest would dispatch.
python3 - "$TMP" <<'PY'
import json, os, sys
d = sys.argv[1]
def sse(events):
    return "".join("event: %s\ndata: %s\n\n" % (e, p) for e, p in events)
def stream(args_delta, item_id="item_M_1", call_id="call_M_0001"):
    ev = []
    ev.append(("response.output_item.added", json.dumps({
        "type": "response.output_item.added",
        "item": {"type": "function_call", "id": item_id, "status": "in_progress",
                 "arguments": "", "call_id": call_id, "name": "get_weather"},
        "output_index": 1, "sequence_number": 1})))
    ev.append(("response.function_call_arguments.delta", json.dumps({
        "type": "response.function_call_arguments.delta", "delta": args_delta,
        "item_id": item_id, "output_index": 1, "sequence_number": 2})))
    ev.append(("response.function_call_arguments.done", json.dumps({
        "type": "response.function_call_arguments.done", "arguments": args_delta,
        "item_id": item_id, "output_index": 1, "sequence_number": 3})))
    ev.append(("response.output_item.done", json.dumps({
        "type": "response.output_item.done",
        "item": {"type": "function_call", "id": item_id, "status": "completed",
                 "arguments": args_delta, "call_id": call_id, "name": "get_weather"},
        "output_index": 1, "sequence_number": 4})))
    ev.append(("response.completed", json.dumps({
        "type": "response.completed", "response": {
            "id": "p", "status": "completed", "output": []}})))
    return sse(ev)
open(os.path.join(d, "mal-num.sse"), "w").write(stream('{"city": "Paris", "justification": 42}'))
open(os.path.join(d, "mal-blank.sse"), "w").write(stream('{"city": "Paris", "justification": "   "}'))
open(os.path.join(d, "mal-notobj.sse"), "w").write(stream('["Paris"]'))
open(os.path.join(d, "mal-null.sse"), "w").write(stream('{"city": "Paris", "justification": null}'))
PY
mal_arm() { # <tag> <stream> <expected-refusal-name> <expected-reason-substring>
    local tag="$1" stream="$2" want="$3" why="$4"
    proxy_roundtrip "$GATE" "$stream" "mal-$tag" --require-justification --deny fx_write
    [ "$RT_RC" -eq 0 ] || fail "phase 32 ($tag): the proxy exited rc=$RT_RC"
    grep -q 'fx_host_denied' "$RT_CAP" || fail "phase 32 ($tag): the reserved name never reached the served bytes"
    grep -q 'get_weather' "$RT_CAP" && fail "phase 32 ($tag): the TRUE NAME crossed the chardev for a refused call"
    n=$(pyq "$RT_LOG" "len([r for r in rows if r.get('call_id')=='call_M_0001' and r.get('verdict')=='denied' and r.get('author')=='justification' and r.get('refusal_name')=='$want' and '$why' in (r.get('reason') or '')])")
    [ "$n" -ge 1 ] || { sed -n '1,3p' "$RT_LOG" >&2; fail "phase 32 ($tag): no row names the refusal $want with a reason containing '$why'"; }
    echo "   OK malformed-$tag: denied BY NAME $want ($why); the true name never crossed"
}
mal_arm num "$TMP/mal-num.sse" malformed-justification "not a JSON string"
mal_arm blank "$TMP/mal-blank.sse" malformed-justification "blank"
mal_arm null "$TMP/mal-null.sse" malformed-justification "null"
mal_arm notobj "$TMP/mal-notobj.sse" malformed-justification "not a JSON object"

echo "== phase 33: P5 THE ARGUMENT MIRROR — the judge must read what the GUEST dispatches"
# THE SHADOW OF THE WHOLE CHECK: a real provider sends arguments:"" in the
# added event and EVERY byte in the deltas (openai_responses.c:171-194).  A
# judge that read the done event's own `arguments` field would deny honest,
# fully justified calls and look protective doing it.  The crafted stream
# below is that provider's shape: the justification arrives ONLY in the deltas,
# the done item's field is empty.  Fixed build: ALLOWED (and it executes).
# Pre-fix control (build/fx-hostgate-doneargs, FH_MUTANT_JUDGE_DONE_ARGS):
# DENIED absent-justification, with the instrument reporting the dead agent.
python3 - "$TMP" <<'PY'
import json, os, sys
d = sys.argv[1]
def sse(events):
    return "".join("event: %s\ndata: %s\n\n" % (e, p) for e, p in events)
ARGS = '{"city": "Paris", "justification": "the user asked for the weather in Paris"}'
ev = []
ev.append(("response.output_item.added", json.dumps({
    "type": "response.output_item.added",
    "item": {"type": "function_call", "id": "item_D_1", "status": "in_progress",
             "arguments": "", "call_id": "call_D_0001", "name": "get_weather"},
    "output_index": 1, "sequence_number": 1})))
ev.append(("response.function_call_arguments.delta", json.dumps({
    "type": "response.function_call_arguments.delta", "delta": ARGS,
    "item_id": "item_D_1", "output_index": 1, "sequence_number": 2})))
ev.append(("response.output_item.done", json.dumps({
    "type": "response.output_item.done",
    "item": {"type": "function_call", "id": "item_D_1", "status": "completed",
             "arguments": "", "call_id": "call_D_0001", "name": "get_weather"},
    "output_index": 1, "sequence_number": 3})))
ev.append(("response.completed", json.dumps({
    "type": "response.completed", "response": {"id": "p", "status": "completed", "output": []}})))
open(os.path.join(d, "delta-only.sse"), "w").write(sse(ev))
PY
proxy_roundtrip "$GATE" "$TMP/delta-only.sse" mirror --require-justification --deny fx_write
[ "$RT_RC" -eq 0 ] || fail "phase 33: the mirror arm exited rc=$RT_RC"
grep -q 'get_weather' "$RT_CAP" \
    || fail "phase 33: a fully justified call (justification delivered in the DELTAS, as a real provider sends it) was NOT allowed — the judge is not reading the guest's accumulator"
grep -q 'fx_host_denied' "$RT_CAP" && fail "phase 33: the reserved name crossed for a call that should have been allowed"
n=$(pyq "$RT_LOG" "len([r for r in rows if r.get('call_id')=='call_D_0001' and r.get('verdict')=='allowed'])")
[ "$n" -ge 1 ] || fail "phase 33: no allowed row for the delta-delivered justification"
n=$(pyq "$RT_LOG" "len([r for r in rows if r.get('call_id')=='call_D_0001' and isinstance(r.get('args'),str) and 'justification' in r['args']])")
[ "$n" -ge 1 ] || fail "phase 33: the row does not record the accumulator's args — the record is not what was judged"
echo "   OK mirror: a delta-delivered justification is ALLOWED and recorded"
proxy_roundtrip "$GATEDONEARGS" "$TMP/delta-only.sse" doneargs --require-justification --deny fx_write
[ "$RT_RC" -eq 0 ] || fail "phase 33: the pre-fix control exited rc=$RT_RC"
grep -q 'fx_host_denied' "$RT_CAP" \
    || fail "phase 33: the done-args-only control did NOT refuse — it is not the pre-fix behavior"
grep -q 'get_weather' "$RT_CAP" && fail "phase 33: the pre-fix control let the true name cross"
n=$(pyq "$RT_LOG" "len([r for r in rows if r.get('call_id')=='call_D_0001' and r.get('refusal_name')=='absent-justification'])")
[ "$n" -ge 1 ] || fail "phase 33: the pre-fix control's refusal is not absent-justification — it is not the mirror defect"
grep -q 'DENIAL RATE 100%' "$RT_ERR" \
    || fail "phase 33: the control's dead-agent shape was not reported by the instrument"
echo "   OK mirror asymmetry: the SAME stream, fully justified, is DENIED by a judge reading the done event's own field (marker/rows/instrument all flip) — the mirror is load-bearing"

echo "== phase 34: P5 NO-JUSTIFICATION-CHECK MUTANT — the model was told and the host ignored it"
# The other half of the check: with the justification check compiled out the
# very same unjustified fixture that phase 31 refuses CROSSES AND EXECUTES.
# The instrument cannot see this one (nothing was denied), which is exactly why
# the marker is the instrument here — stated, not glossed.
mkdir -p "$TMP/data-nojust" "$TMP/cfg-nojust"
make_marker_stub "$TMP/mcp_marker34.py" "$TMP/marker34"
cat > "$TMP/cfg-nojust/config.dhall" <<DHALL
{ agents =
  [ { name = "fx"
    , agent_type = "agent"
    , mcp_servers = [ { command = "$TMP/mcp_marker34.py", args = [] : List Text } ]
    }
  ]
}
DHALL
"$GATENOJUST" --upstream "$TMP/upstream2.sse" --slave-file "$TMP/slave34" \
    --log "$TMP/log-nojust34.jsonl" --require-justification --turns 2 2> "$TMP/proxy34.err" &
PROXY34=$!
PROXIES="$PROXIES $PROXY34"
wait_for_slave "$TMP/slave34" "$PROXY34" "$TMP/proxy34.err"
DEV34=$(cat "$TMP/slave34")
out=$(FX_CHARDEV="$DEV34" FX_AGENT_CONFIG_DIR="$TMP/cfg-nojust" \
    FX_AGENT_DATA="$TMP/data-nojust" HOME="$TMP" \
    "$BIN" -p "$SENTINEL" --agent fx --max-turns 2 --output text)
rc=$?
[ "$rc" -eq 0 ] || { sed -n '1,12p' "$TMP/proxy34.err" >&2; fail "phase 34: the mutant run rc=$rc"; }
wait_for_proxy_exit "$PROXY34" "$TMP/proxy34.err"
[ -f "$TMP/marker34" ] \
    || fail "phase 34: the marker is ABSENT — the mutant did not reproduce the fail-open; the phase-31 marker-absence would then prove nothing about the check"
TR=$(ls "$TMP"/data-nojust/sessions/*/messages.jsonl 2>/dev/null)
n=$(pyq "$TR" "len([1 for r in rows for tc in (r.get('tool_calls') or []) if tc.get('name')=='get_weather'])")
[ "$n" -ge 1 ] || fail "phase 34: the mutant did not dispatch the true name — not the fail-open"
n=$(pyq "$TMP/log-nojust34.jsonl" "len([r for r in rows if r.get('call_id')=='$CALLID' and r.get('verdict')=='allowed'])")
[ "$n" -ge 1 ] || fail "phase 34: the mutant's record does not say allowed"
echo "   OK no-justify-check asymmetry: an unjustified call EXECUTED under --require-justification while phase 31 refused the same fixture — the check is what stops it"

echo "== phase 35: P5 NO-DENIAL-RATE MUTANT — the instrument compiled out is BLIND, and that is asserted"
# The instrument's own mutation blind: the refusals still happen (same fixture,
# same flag) but NOTHING in the record or on stderr says the lane is dead.  If
# this phase passes, phase 31b's instrument is load-bearing rather than
# decorative.
proxy_roundtrip "$GATENODRATE" "$TMP/upstream2.sse" nodrate --require-justification --deny fx_write
[ "$RT_RC" -eq 0 ] || fail "phase 35: the mutant exited rc=$RT_RC"
grep -q 'fx_host_denied' "$RT_CAP" \
    || fail "phase 35: the mutant did not refuse at all — the instrument arm is not isolating the instrument"
n=$(pyq "$RT_LOG" "len([r for r in rows if r.get('verdict')=='denied' and r.get('refusal_name')=='absent-justification'])")
[ "$n" -ge 1 ] || fail "phase 35: the denial is not in the record — the blindness arm depends on the denial happening"
n=$(pyq "$RT_LOG" "len([1 for r in rows if r.get('type')=='turn-stats'])")
[ "$n" -eq 0 ] || fail "phase 35: the mutant STILL emitted turn-stats rows"
n=$(pyq "$RT_LOG" "len([1 for r in rows if r.get('type')=='proxy-exit' and 'calls_total' in r])")
[ "$n" -eq 0 ] || fail "phase 35: the mutant STILL emitted the exit aggregate"
grep -q 'DENIAL RATE 100%' "$RT_ERR" && fail "phase 35: the mutant still printed the 100%-denied line"
grep -q 'ALL [0-9]* call(s) DENIED' "$RT_ERR" && fail "phase 35: the mutant still printed the run-level dead-agent line"
grep -q 'denial-rate instrument: COMPILED OUT' "$RT_ERR" \
    || fail "phase 35: the mutant does not say the instrument is compiled out (a silent blindness is not the mutant being pinned)"
echo "   OK instrument asymmetry: identical refusals, and the dead-agent shape leaves NO trace in the record or on stderr — phase 31b's instrument is what makes it visible"

echo "== phase 36: P5 ZERO GUEST CHANGE — every verb IGNORES the riding justification key (differential, against the REAL server)"
# The design says the justification RIDES WITH THE CALL through the guest into
# the verb, which is sound ONLY if no verb is strict about unknown argument
# keys (fx-verbs-server.c:2548-2557 extracts arguments BY KEY).  That is a
# source claim until it is measured, so this phase drives the REAL verbs server
# twice per verb — with and without a riding `justification` key — and requires
# BYTE-IDENTICAL replies, for all 13.  It also requires the probe ITSELF to be
# able to fail: a third call mutating a MEANINGFUL argument must change the
# reply, or the identical-with-and-without result would prove nothing (an
# instrument that cannot disagree is not evidence).
# If a verb ever becomes strict the gate fails HERE, and the remedy is
# host-side — the host owns the wire and can STRIP the key — never a guest
# change.  A missing server binary is a LOUD SKIP: a substitute would measure a
# substitute.
if [ ! -x "$ROOT/build/fx-verbs-server" ]; then
    echo "   SKIP phase 36: build/fx-verbs-server is not built — the REAL verbs server is the oracle for this property and no stand-in may replace it"
else
python3 - "$ROOT" "$TMP/verbs-pinned.txt" <<'PY'
import json, os, subprocess, sys
root, verbs_file = sys.argv[1], sys.argv[2]
server = os.path.join(root, "build", "fx-verbs-server")
verbs = [v.strip() for v in open(verbs_file) if v.strip()]
assert len(verbs) == 13, verbs
# the probe's own sandbox: an empty root and no store, so every verb's reply is
# a deterministic refusal/one-liner rather than a fact about this host.
env = dict(os.environ)
env["FX_VERB_ROOT"] = os.environ.get("FX_VERB_PROBE_ROOT", "/tmp/hostgate-verbs-probe-root")
env["FX_RUN"] = "/tmp/hostgate-verbs-probe-run"
env["PATH"] = "/usr/bin:/bin"
env.pop("FX_AGENT_WRITABLE", None)
env.pop("FX_AGENT_BUILDABLE", None)
os.makedirs(env["FX_VERB_ROOT"], exist_ok=True)
ARGS = {
    "fx_query": {"relation": "generation"},
    "fx_rollback": {"version": "1"},
    "fx_what": {"target": "/x"},
    "fx_why": {"package": "x"},
    "fx_read": {"path": "/etc/hostname"},
    "fx_write": {"path": env["FX_VERB_ROOT"] + "/w.txt", "content": "x"},
    "fx_ls": {"path": "/"},
    "fx_activate": {"config": "/x"},
    "fx_build": {"package": "x"},
}
# a MEANINGFUL mutation per verb, for the can-this-probe-fail control
MUTATE = {"fx_read": {"path": "/etc/does-not-exist-hostgate"},
          "fx_ls": {"path": "/proc/1/fd"},
          "fx_query": {"relation": "svc"},
          "fx_write": {"path": env["FX_VERB_ROOT"] + "/other.txt", "content": "x"},
          "fx_what": {"target": "/y"},
          "fx_build": {"package": "y"}}
def call(name, args):
    inp = json.dumps({"jsonrpc": "2.0", "id": 0, "method": "initialize",
                      "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                                 "clientInfo": {"name": "probe", "version": "0"}}}) + "\n"
    inp += json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                       "params": {"name": name, "arguments": args}}) + "\n"
    p = subprocess.run([server], input=inp, capture_output=True, text=True,
                       env=env, timeout=30)
    reps = [json.loads(l) for l in p.stdout.splitlines() if l.strip()]
    r = [x for x in reps if x.get("id") == 1]
    assert len(r) == 1, (name, p.stdout[:200], p.stderr[:200])
    return json.dumps(r, sort_keys=True)
bad = []
for v in verbs:
    base = dict(ARGS.get(v, {}))
    with_j = dict(base, justification="the user asked for this; probe only")
    a, b = call(v, base), call(v, with_j)
    if a != b:
        bad.append((v, a[:120], b[:120]))
detectable = 0
for v, mut in MUTATE.items():
    if v not in verbs:
        continue
    base = dict(ARGS.get(v, {}))
    if call(v, base) != call(v, dict(base, **mut)):
        detectable += 1
if bad:
    for v, a, b in bad:
        print("DIFFER %s\n  without: %s\n  with:    %s" % (v, a, b))
    sys.exit("the riding justification key CHANGED %d verb reply/replies — a strict verb would need host-side stripping" % len(bad))
assert detectable >= 1, ("the probe cannot detect ANY argument difference — its identical replies prove nothing", detectable)
print("all %d verbs returned byte-identical replies with and without the riding "
      "justification key; the probe can still detect a real argument change (%d verb(s) differ)"
      % (len(verbs), detectable))
PY
rc=$?
[ "$rc" -eq 0 ] || fail "phase 36: the riding justification key is not transparent to every verb (rc=$rc) — the host would have to strip it (host-side), never the guest"
fi

echo "== phase 37: P5 THE JUDGMENT SOURCE IS THE GUEST'S SOURCE — a justification the guest DROPS must not justify a call"
# THE DEFECT THIS PHASE PINS (found by review AFTER the gate was green): the
# judge's no-delta fallback read output_item.done's item.arguments — a field
# the GUEST NEVER READS.  At that event the guest emits its accumulator AS-IS
# (openai_responses.c:171-194; possibly empty) and its ONLY fallback is the
# response.function_call_arguments.done EVENT.  So a stream carrying its
# justification ONLY in the done item's field made the host record a justified
# call and ALLOW it while the guest, its accumulator empty, dispatched the same
# call with "{}" (the review reproduced that end-to-end: served bytes allowed,
# row args carrying the justification, the verb receiving args={} — that
# measurement is theirs, quoted; the served bytes below are this phase's).
# The stream: added(arguments:"") -> NO deltas, NO arguments.done ->
# output_item.done(item.arguments=<justified>) -> completed.
# FIXED build: the accumulator is empty -> absent-justification -> the RESERVED
# name on the wire.  Pre-fix control (build/fx-hostgate-doneargs,
# FH_MUTANT_JUDGE_DONE_ARGS): reads the done item's field -> ALLOWS -> the TRUE
# NAME crosses and the row claims a justification that never rode with a call.
python3 - "$TMP" <<'PY'
import json, os, sys
d = sys.argv[1]
def sse(events):
    return "".join("event: %s\ndata: %s\n\n" % (e, p) for e, p in events)
JUST = '{"city": "Paris", "justification": "the user asked for the weather in Paris"}'
ev = []
ev.append(("response.output_item.added", json.dumps({
    "type": "response.output_item.added",
    "item": {"type": "function_call", "id": "item_DO_1", "status": "in_progress",
             "arguments": "", "call_id": "call_DO_0001", "name": "get_weather"},
    "output_index": 1, "sequence_number": 1})))
ev.append(("response.output_item.done", json.dumps({
    "type": "response.output_item.done",
    "item": {"type": "function_call", "id": "item_DO_1", "status": "completed",
             "arguments": JUST, "call_id": "call_DO_0001", "name": "get_weather"},
    "output_index": 1, "sequence_number": 2})))
ev.append(("response.completed", json.dumps({
    "type": "response.completed", "response": {"id": "p", "status": "completed", "output": []}})))
open(os.path.join(d, "done-only.sse"), "w").write(sse(ev))
# the NEVER-OPENED shape (item (b) of the same review): a done for an item
# whose added NEVER arrived — the guest dispatches NOTHING (its accumulator is
# fed only by added), so this is a refusal the host serves with no
# function_call_output leg at all.
ev2 = []
ev2.append(("response.output_item.done", json.dumps({
    "type": "response.output_item.done",
    "item": {"type": "function_call", "id": "item_UN_1", "status": "completed",
             "arguments": "{}", "call_id": "call_UN_0002", "name": "fx_write"},
    "output_index": 1, "sequence_number": 1})))
ev2.append(("response.completed", json.dumps({
    "type": "response.completed", "response": {"id": "p", "status": "completed", "output": []}})))
open(os.path.join(d, "unopened-done.sse"), "w").write(sse(ev2))
# the OPEN-AT-COMPLETED shape (item (a)): a denied item still open when
# completed arrives, so the deny map is seeded from the open item rather than
# from a judgment — and completed's output array carries the item too.
def fc_ov():
    return {"type": "function_call", "id": "item_OV_1", "status": "in_progress",
            "arguments": "", "call_id": "call_OV_0001", "name": "fx_write"}
ev3 = [("response.output_item.added", json.dumps({
        "type": "response.output_item.added",
        "item": fc_ov(), "output_index": 1, "sequence_number": 1})),
       ("response.completed", json.dumps({
           "type": "response.completed", "response": {
               "id": "p", "object": "response", "status": "completed",
               "output": [fc_ov()]}}))]
open(os.path.join(d, "raw-open37.sse"), "w").write(sse(ev3))
PY
proxy_roundtrip "$GATE" "$TMP/done-only.sse" doneonly --require-justification --deny fx_write
[ "$RT_RC" -eq 0 ] || fail "phase 37: the fixed build exited rc=$RT_RC"
grep -q 'fx_host_denied' "$RT_CAP" \
    || fail "phase 37: a justification present ONLY in output_item.done's item field (a field the guest never reads) was NOT refused — the judge is not reading the guest's source"
grep -q 'get_weather' "$RT_CAP" && fail "phase 37: the TRUE name crossed the chardev for a call the guest dispatches with no justification"
n=$(pyq "$RT_LOG" "len([r for r in rows if r.get('call_id')=='call_DO_0001' and r.get('verdict')=='denied' and r.get('author')=='justification' and r.get('refusal_name')=='absent-justification'])")
[ "$n" -ge 1 ] || { sed -n '1,3p' "$RT_LOG" >&2; fail "phase 37: no absent-justification row — the refusal is not the judgment-source refusal"; }
n=$(pyq "$RT_LOG" "len([r for r in rows if r.get('call_id')=='call_DO_0001' and 'justification' not in (r.get('args') or '')])")
[ "$n" -ge 1 ] || fail "phase 37: the row records the done item's field as the judged args — the record is not what the judge read"
n=$(pyq "$RT_LOG" "len([1 for r in rows if r.get('type')=='turn-stats' and r.get('calls')==1 and r.get('denied')==1 and r.get('denial_rate')==1.0])")
[ "$n" -ge 1 ] || fail "phase 37: the instrument did not report the refusal (1 call, 1 denied, rate 1.0)"
echo "   OK done-only: judged on the EMPTY accumulator -> absent-justification, reserved name on the served bytes, and the row records the EMPTY args that were judged"
proxy_roundtrip "$GATEDONEARGS" "$TMP/done-only.sse" doneonly-ctl --require-justification --deny fx_write
[ "$RT_RC" -eq 0 ] || fail "phase 37: the pre-fix control exited rc=$RT_RC"
grep -q 'get_weather' "$RT_CAP" \
    || fail "phase 37: the done-args-only control did NOT let the true name cross — it is not the pre-fix behavior"
grep -q 'fx_host_denied' "$RT_CAP" && fail "phase 37: the pre-fix control refused a stream it used to allow — the control is not the pre-fix judgment source"
n=$(pyq "$RT_LOG" "len([r for r in rows if r.get('call_id')=='call_DO_0001' and r.get('verdict')=='allowed' and 'justification' in (r.get('args') or '')])")
[ "$n" -ge 1 ] || fail "phase 37: the control's row does not claim a justification the guest never dispatched — the bypass is not reproduced"
echo "   OK judgment-source asymmetry: the SAME bytes are DENIED by the fixed build (empty accumulator) and ALLOWED by the doneargs control, whose row claims a justification the guest drops — the bypass the review reproduced is now gated"
# item (b): the never-opened-done refusal must be COUNTED (it wrote no row at
# all before), or the denial-rate instrument reads its own blind spot as
# "nothing happened" (calls=0, denial_rate=null).
proxy_roundtrip "$GATE" "$TMP/unopened-done.sse" unopened --require-justification --deny fx_write
[ "$RT_RC" -eq 0 ] || fail "phase 37: the never-opened arm exited rc=$RT_RC"
grep -q 'fx_host_denied' "$RT_CAP" \
    || fail "phase 37: the never-opened denied done was NOT rewritten — the true name crossed for a refused call"
grep -q 'fx_write' "$RT_CAP" && fail "phase 37: the true name of a NEVER-OPENED denied item crossed the chardev"
n=$(pyq "$RT_LOG" "len([r for r in rows if r.get('call_id')=='call_UN_0002' and r.get('verdict')=='denied' and r.get('refusal_name')=='denied-by-denylist'])")
[ "$n" -ge 1 ] || fail "phase 37: the never-opened refusal wrote NO row — the denial-rate instrument is blind to this shape"
n=$(pyq "$RT_LOG" "len([r for r in rows if r.get('type')=='turn-stats' and r.get('calls')==1 and r.get('denied')==1])")
[ "$n" -ge 1 ] || fail "phase 37: the instrument did not count the never-opened refusal"
n=$(pyq "$RT_LOG" "len([1 for r in rows if r.get('type')=='proxy-exit' and r.get('calls_total')==1 and r.get('denied_total')==1])")
[ "$n" -ge 1 ] || fail "phase 37: the exit aggregate does not carry the never-opened refusal"
echo "   OK never-opened-done: refused AND counted (row + turn-stats + exit aggregate), where it used to write no row at all"
# item (a): the completed-with-open-item SEEDING used to store an EMPTY denial
# text, and the leg that CONSUMES it is the outbound substitution for that
# call_id in the NEXT request: an empty text puts a BLANK tool result in front
# of the model.  The arm below drives exactly that leg (a raw two-frame client:
# turn 1 leaves the denied item open at completed, turn 2 replays its
# function_call_output) and reads the SUBSTITUTED output out of the dump.
mkdir -p "$TMP/seed"
"$GATE" --upstream "$TMP/raw-open37.sse" --slave-file "$TMP/seed/slave" \
    --log "$TMP/seed/log.jsonl" --dump-requests "$TMP/seed/dump.jsonl" \
    --deny fx_write --turns 2 2> "$TMP/seed/proxy.err" &
PROXY37=$!
PROXIES="$PROXIES $PROXY37"
wait_for_slave "$TMP/seed/slave" "$PROXY37" "$TMP/seed/proxy.err"
DEV37=$(cat "$TMP/seed/slave")
python3 - "$DEV37" <<'PY'
import json, os, select, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_APPEND)
def frame(inp):
    f = json.dumps({"model": "m", "stream": True, "input": inp})
    os.write(fd, f"{len(f)}\n{f}".encode())
def drain(deadline):
    data = b""
    while time.time() < deadline:
        try:
            r, _, _ = select.select([fd], [], [], 1)
        except OSError:
            break
        if not r:
            continue
        try:
            b = os.read(fd, 65536)
        except OSError:
            break
        if not b:
            break
        data += b
        if b"response.completed" in data:
            tail = time.time() + 0.5
            while time.time() < tail:
                try:
                    r, _, _ = select.select([fd], [], [], 0.5)
                except OSError:
                    break
                if not r:
                    break
                try:
                    b = os.read(fd, 65536)
                except OSError:
                    break
                if not b:
                    break
                data += b
            break
    return data
frame([{"type": "message", "role": "user", "content": "hi"}])
drain(time.time() + 20)
# turn 2: the refused call's own result, replayed under the SAME call_id
frame([{"type": "message", "role": "user", "content": "hi"},
       {"type": "function_call_output", "call_id": "call_OV_0001",
        "output": "(tool call failed)"}])
drain(time.time() + 20)
os.close(fd)
PY
wait_for_proxy_exit "$PROXY37" "$TMP/seed/proxy.err"
n=$(python3 - "$TMP/seed/dump.jsonl" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
outs = [it.get("output") for r in rows for it in (r.get("input") or [])
        if it.get("type") == "function_call_output"
        and it.get("call_id") == "call_OV_0001"]
print(len([o for o in outs if o and "item never completed" in o]))
PY
)
[ "$n" -ge 1 ] || fail "phase 37: the seeded denial text did not reach the outbound substitution — the model would see a BLANK tool result for the un-judged item"
n=$(python3 - "$TMP/seed/dump.jsonl" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
outs = [it.get("output") for r in rows for it in (r.get("input") or [])
        if it.get("type") == "function_call_output"
        and it.get("call_id") == "call_OV_0001"]
print(len([o for o in outs if o == ""]))
PY
)
[ "$n" -eq 0 ] || fail "phase 37: an EMPTY denial text was substituted for the un-judged item's call_id (a blank tool result)"
echo "   OK seeding: the completed-with-open-item refusal substitutes a REAL denial text (never an empty output) for that call_id's replay"

# ── P6: THE OPERATOR AUTHOR AT THE HOST SEAT ────────────────────────────────
#
# WHERE THE S1/S2 ARMS WENT, stated: tests/test_ops_policy.sh is the PIN-TIME
# artifact gate (le compile, lint, alias checking, engine-level fact
# derivation) and it stays UNTOUCHED and green — it is the artifact authority
# and it has no proxy in it.  The property the brief names ("a rule that
# DENIES in the artifact must DENY at the host seat, ON A REAL CALL") is
# therefore MIRRORED here as phases 38-44, driven against the REAL
# policy/ops/ artifacts through the REAL proxy and (where a call must execute)
# through the REAL guest harness.  These phases are SELF-VERIFYING against
# those artifacts and do not need test_ops_policy.sh to be re-pointed (which
# would have made the artifact gate depend on the host binary and lose its
# role as the independent authority).
#
# FAILURE DIRECTIONS, named per arm: a seat that does not deny what the pinned
# policy denies is FAIL-OPEN (phase 40's control); a seat that binds the floor
# it cannot see OVER-DENIES (phase 41's control); a seat that matches the RAW
# path against the pinned patterns is a SILENT ALLOW on exactly the spellings
# the in-guest seat refuses (phase 43's control); a seat whose startup line
# does not NAME which rules are live would be a record claiming more than it
# enforces (phase 38); and a seat that keeps acting on a policy whose every
# rule is INERT here would claim an author that cannot refuse (phase 44's
# D2-only arm, the branch the review found unpinned).
#
# AND THE RECORD'S OWN HONESTY (P6-fix, the review's SHOULD-FIX): an ALLOWED
# row carries allow_scope — the seat-scoped reading ("no operator denial at
# this seat; the in-guest floor and D2 still govern") — because the qualifier
# used to live only in the TRANSIENT startup line while the one log is what a
# reader sees AT REST.  A row that reads as a permission this seat never
# grants is the over-claim this project keeps paying for, so phase 41 ASSERTS
# the qualifier on the D2-bound allowed row instead of documenting it.

OPS_DIR="$ROOT/policy/ops"

# ops_stream <dest> <name> <path> <call-id> [<name> <path> <call-id>]... —
# one or more function_calls in the real-provider shape: arguments:"" in added,
# every byte in the DELTAS, the full args in arguments.done/item.done/
# completed.  The delta delivery is load-bearing (P5's phase 33/37
# discipline): the host judges the ACCUMULATOR, which is also what the guest
# dispatches, so a stream carrying args only in the done item's own field
# would be judged on empty arguments.
ops_stream() { # <dest> <name> <path> <call-id> ...
    python3 - "$@" <<'PY'
import json, sys
dest = sys.argv[1]
triples = [tuple(sys.argv[i:i + 3]) for i in range(2, len(sys.argv), 3)]
ev = []
seq = 0
completed = []
for n, (name, path, cid) in enumerate(triples, start=1):
    iid = "item_OP_%d" % n
    args = json.dumps({"path": path})
    def fc(status):
        return {"type": "function_call", "id": iid, "status": status,
                "arguments": args, "call_id": cid, "name": name}
    seq += 1
    ev.append(("response.output_item.added", json.dumps({
        "type": "response.output_item.added",
        "item": {"type": "function_call", "id": iid, "status": "in_progress",
                 "arguments": "", "call_id": cid, "name": name},
        "output_index": n, "sequence_number": seq})))
    seq += 1
    ev.append(("response.function_call_arguments.delta", json.dumps({
        "type": "response.function_call_arguments.delta", "delta": args,
        "item_id": iid, "output_index": n, "sequence_number": seq})))
    seq += 1
    ev.append(("response.function_call_arguments.done", json.dumps({
        "type": "response.function_call_arguments.done", "arguments": args,
        "item_id": iid, "output_index": n, "sequence_number": seq})))
    seq += 1
    ev.append(("response.output_item.done", json.dumps({
        "type": "response.output_item.done", "item": fc("completed"),
        "output_index": n, "sequence_number": seq})))
    completed.append(fc("completed"))
ev.append(("response.completed", json.dumps({
    "type": "response.completed",
    "response": {"id": "p", "status": "completed", "output": completed}})))
open(dest, "w").write("".join("event: %s\ndata: %s\n\n" % (e, p) for e, p in ev))
PY
}

# ops_guest_arm <gate> <upstream> <tag> <policy-dir> [extra argv...] — the
# whole guest loop THROUGH the proxy with a two-verb dispatch-recording stub
# (get_weather / fx_write, phase 28's discipline): the arm asserts on the
# transcript, the dispatch MARKER, the dumped outbound frame and the log.
# Exports OG_TR OG_LOG OG_DUMP OG_ERR OG_MW OG_MWW OG_RC.
ops_guest_arm() {
    local gate="$1" upstream="$2" tag="$3" pdir="$4"
    shift 4
    local data="$TMP/ops-data-$tag"
    local cfg="$TMP/ops-cfg-$tag"
    local mw="$TMP/ops-marker-$tag-write"
    local mww="$TMP/ops-marker-$tag-weather"
    mkdir -p "$data" "$cfg"
    make_multi_stub "$TMP/ops-stub-$tag.py" "$mww" "$mw"
    cat > "$cfg/config.dhall" <<DHALL
{ agents =
  [ { name = "fx"
    , agent_type = "agent"
    , mcp_servers = [ { command = "$TMP/ops-stub-$tag.py", args = [] : List Text } ]
    }
  ]
}
DHALL
    "$gate" --upstream "$upstream" --slave-file "$TMP/ops-slave-$tag" \
        --log "$TMP/ops-log-$tag.jsonl" --dump-requests "$TMP/ops-dump-$tag.jsonl" \
        --ops-policy-dir "$pdir" "$@" --turns 2 2> "$TMP/ops-err-$tag" &
    local p=$!
    PROXIES="$PROXIES $p"
    wait_for_slave "$TMP/ops-slave-$tag" "$p" "$TMP/ops-err-$tag"
    local dev
    dev=$(cat "$TMP/ops-slave-$tag")
    FX_CHARDEV="$dev" FX_AGENT_CONFIG_DIR="$cfg" \
    FX_AGENT_DATA="$data" HOME="$TMP" \
        "$BIN" -p "$SENTINEL" --agent fx --max-turns 2 --output text \
        > "$TMP/ops-stdout-$tag" 2> "$TMP/ops-guesterr-$tag"
    OG_RC=$?
    wait_for_proxy_exit "$p" "$TMP/ops-err-$tag"
    OG_TR=$(ls "$data"/sessions/*/messages.jsonl 2>/dev/null)
    OG_LOG="$TMP/ops-log-$tag.jsonl"
    OG_DUMP="$TMP/ops-dump-$tag.jsonl"
    OG_ERR="$TMP/ops-err-$tag"
    OG_MW="$mw"
    OG_MWW="$mww"
}

# ops_repin <dir> — recompute PINS for ops-aliases.tsv and ops-policy.dl in a
# COPY of the policy dir, so a mutated table is a VALID pinned release: the
# arm then tests the seat's check, not the pin's refusal.
ops_repin() {
    local d="$1"
    local tsv sha_dl sha_lex
    tsv=$(sha256sum "$d/ops-aliases.tsv" | cut -d' ' -f1)
    sha_dl=$(sha256sum "$d/ops-policy.dl" | cut -d' ' -f1)
    sha_lex=$(sha256sum "$d/ops-lexicon.ini" | cut -d' ' -f1)
    grep -v '^ops-aliases.tsv' "$d/PINS" | grep -v '^ops-policy.dl' \
        | grep -v '^ops-lexicon.ini' > "$d/PINS.new"
    printf 'ops-lexicon.ini\t%s\nops-policy.dl\t%s\nops-aliases.tsv\t%s\n' \
        "$sha_lex" "$sha_dl" "$tsv" >> "$d/PINS.new"
    mv "$d/PINS.new" "$d/PINS"
}

echo "== phase 38: P6 THE SEAT'S STARTUP LINE NAMES THE D1/D2 SPLIT (and the floor it does NOT have)"
# (a) THE SPLIT IS READ OUT OF THE ARTIFACT, not asserted from a plan: the two
# rules of policy/ops/ops-policy.dl are quoted here and must appear verbatim,
# and the C seat this seat ports must be consulted from EXACTLY ONE commit
# site, inside native_write — the provenance of the pinned write-verb set.
r1='denied(W1, P1) :- touches(W1, P1), kind(W1, write), class(P1, C1), protected(C1).'
r2='denied(W1, P1) :- touches(W1, P1), kind(W1, write), writable(P1), !boot_verdict(ok).'
grep -qF "$r1" "$OPS_DIR/ops-policy.dl" \
    || fail "phase 38: the pinned artifact does not carry D1 as the rule text read here"
grep -qF "$r2" "$OPS_DIR/ops-policy.dl" \
    || fail "phase 38: the pinned artifact does not carry D2 as the rule text read here"
n=$(grep -c '!ops_write_allowed(' "$ROOT/tools/fx-verbs-server.c")
[ "$n" -eq 1 ] || fail "phase 38: the in-guest ops seat has $n commit sites, not one — the write-verb set pinned in the proxy may be incomplete"
csite=$(grep -n '!ops_write_allowed(' "$ROOT/tools/fx-verbs-server.c" | cut -d: -f1)
ndef=$(grep -n '^static int native_write' "$ROOT/tools/fx-verbs-server.c" | cut -d: -f1)
[ -n "$ndef" ] && [ "$csite" -gt "$ndef" ] \
    || fail "phase 38: the single ops commit site is not inside native_write (def=$ndef call=$csite) — the write-verb provenance is wrong"
nxt=$(awk -v s="$ndef" 'NR>s && /^static /{print NR; exit}' "$ROOT/tools/fx-verbs-server.c")
[ "$csite" -lt "$nxt" ] || fail "phase 38: the ops commit site ($csite) is not inside native_write (which ends at $nxt)"
echo "   OK split source: the artifact's own D1/D2 lines are quoted; the in-guest seat has ONE commit site, inside native_write (line $csite) — the pinned write-verb set's provenance"
# (b) the STARTUP LINE, on the real build with the real dir: it names D1 live,
# D2 inert WITH ITS REASON, and states the floor is in-guest only.  Nothing is
# driven — the proxy is started bounded and reaped.
mkdir -p "$TMP/p6-start"
"$GATE" --upstream "$TMP/upstream2.sse" --slave-file "$TMP/p6-start/slave" \
    --log "$TMP/p6-start/log.jsonl" --ops-policy-dir "$OPS_DIR" --turns 1 \
    2> "$TMP/p6-start/err" &
P6S=$!
PROXIES="$PROXIES $P6S"
wait_for_slave "$TMP/p6-start/slave" "$P6S" "$TMP/p6-start/err"
kill "$P6S" 2>/dev/null
wait "$P6S" 2>/dev/null
for want in "1 LIVE at this seat (D1)" "INERT AT THIS SEAT (D2)" \
            "boot_verdict" "never injects writable" "THE FLOOR" \
            "enforced IN-GUEST ONLY" "has NO floor of its own"; do
    grep -qF "$want" "$TMP/p6-start/err" \
        || { sed -n '1,8p' "$TMP/p6-start/err" >&2; fail "phase 38: the startup line does not name '$want' — the seat does not say what it does and does not enforce"; }
done
grep -qF "authors armed = ops" "$TMP/p6-start/err" \
    || fail "phase 38: the honesty line does not name the ops author as armed"
echo "   OK startup line: D1 named LIVE, D2 named INERT with its reason (writable/boot_verdict), the floor stated as IN-GUEST ONLY and explicitly NOT held here"
# (c) the NAMED no-policy state: with no --ops-policy-dir the seat says so,
# and the proxy still starts (a per-seat state, never an error).
mkdir -p "$TMP/p6-nopol"
"$GATE" --upstream "$TMP/upstream2.sse" --slave-file "$TMP/p6-nopol/slave" \
    --log "$TMP/p6-nopol/log.jsonl" --turns 1 2> "$TMP/p6-nopol/err" &
P6N=$!
PROXIES="$PROXIES $P6N"
wait_for_slave "$TMP/p6-nopol/slave" "$P6N" "$TMP/p6-nopol/err"
kill "$P6N" 2>/dev/null
wait "$P6N" 2>/dev/null
grep -qF "ops-policy: NONE" "$TMP/p6-nopol/err" \
    || fail "phase 38: with no policy dir the seat does not name its state"
echo "   OK no-policy state: named once, not an error"

echo "== phase 39: P6 D1 DENIES AT THE HOST SEAT — a real call, the P3 invariant intact"
# THE RE-POINTED PROPERTY: the rule that DENIES in the pinned artifact denies
# at the host seat on a real call.  /fx/disk/agent-config.dhall is the
# Agentconfig row's EXACT pattern, protected=yes, so D1 fires.  Everything is
# asserted by CONTENT (the run exits 0 in every arm, the log looks protective
# in every arm).
ops_stream "$TMP/ops-protected.sse" fx_write "/fx/disk/agent-config.dhall" call_OP_0001
ops_guest_arm "$GATE" "$TMP/ops-protected.sse" protected "$OPS_DIR"
[ "$OG_RC" -eq 0 ] || { sed -n '1,10p' "$OG_ERR" >&2; fail "phase 39: the guest run rc=$OG_RC"; }
[ -f "$OG_TR" ] || fail "phase 39: no guest transcript — the arm is not the real scenario"
# (a) THE CHANNEL INVARIANT holds for an OPS denial too
n=$(pyq "$OG_TR" "len([1 for r in rows for tc in (r.get('tool_calls') or []) if tc.get('name')=='fx_host_denied' and tc.get('id')=='call_OP_0001'])")
[ "$n" -eq 1 ] || fail "phase 39: the transcript does not carry the call as fx_host_denied — the ops denial did not take the rewrite path"
n=$(pyq "$OG_TR" "len([1 for r in rows for tc in (r.get('tool_calls') or []) if tc.get('name')=='fx_write'])")
[ "$n" -eq 0 ] || fail "phase 39: THE TRUE NAME fx_write reached the guest as a call name — the invariant is broken for an ops denial"
n=$(pyq "$OG_TR" "len([1 for r in rows if r.get('role')=='tool' and r.get('tool_call_id')=='call_OP_0001' and r.get('content')=='(tool call failed)'])")
[ "$n" -eq 1 ] || fail "phase 39: the guest's sentinel for the reserved name is missing — the structural backstop did not run"
# (b) nothing executed
[ ! -e "$OG_MW" ] || fail "phase 39: THE fx_write MARKER IS PRESENT — a call the operator policy denies EXECUTED"
# (c) the outbound leg carries the truth
n=$(pyq "$OG_DUMP" "len([r for r in rows if any(i.get('type')=='function_call' and i.get('call_id')=='call_OP_0001' and i.get('name')=='fx_write' for i in r.get('input',[]))])")
[ "$n" -ge 1 ] || fail "phase 39: the dumped frame does not RESTORE the true name for the denied call"
n=$(pyq "$OG_DUMP" "len([r for r in rows if any(i.get('type')=='function_call_output' and i.get('call_id')=='call_OP_0001' and isinstance(i.get('output'),str) and i['output'].startswith('(denied by host policy:') for i in r.get('input',[]))])")
[ "$n" -ge 1 ] || fail "phase 39: the denial text did not reach the model as the call's own result"
# (d) the log row names the REAL author, the by-name refusal and the rule
n=$(pyq "$OG_LOG" "len([r for r in rows if r.get('call_id')=='call_OP_0001' and r.get('verdict')=='denied' and r.get('author')=='ops' and r.get('refusal_name')=='denied-by-ops' and 'rule D1' in (r.get('reason') or '') and '/fx/disk/agent-config.dhall' in (r.get('reason') or '') and (r.get('denial_text') or '').startswith('(denied by host policy:')])")
[ "$n" -ge 1 ] || { sed -n '1,3p' "$OG_LOG" >&2; fail "phase 39: no row carries verdict=denied author=ops refusal_name=denied-by-ops with the FIRED RULE D1 and the path"; }
echo "   OK D1 at the host seat: fx_host_denied on the wire (never fx_write), NO dispatch, the restored name + denial text on the outbound leg, and a row naming author=ops rule D1"
# NO LATCH: the per-call facts are injected and RETRACTED per call (the in-guest
# seat's collect-then-mutate discipline; its own comment claims the retraction
# also retracts the DERIVED rows, so nothing latches).  A seat that latched
# would OVER-DENY — the second, unprotected call in the SAME pass would be
# denied by the first call's materialized rows — so the property is MEASURED,
# not assumed: one pass, two calls, DIFFERENT verdicts.
ops_stream "$TMP/ops-two.sse" fx_write "/fx/disk/agent-config.dhall" call_OP_L1 \
    fx_write "/fx/disk/agent-data" call_OP_L2
proxy_roundtrip "$GATE" "$TMP/ops-two.sse" opslatch --ops-policy-dir "$OPS_DIR"
[ "$RT_RC" -eq 0 ] || fail "phase 39: the no-latch arm exited rc=$RT_RC"
grep -q 'fx_host_denied' "$RT_CAP" \
    || fail "phase 39: the protected call was not denied in the two-call pass"
grep -q 'fx_write' "$RT_CAP" \
    || fail "phase 39: the UNPROTECTED call was denied too — the per-call facts LATCH (an over-deny): the first call's materialized rows survived its retraction"
n=$(pyq "$RT_LOG" "len([r for r in rows if r.get('call_id')=='call_OP_L1' and r.get('verdict')=='denied' and r.get('author')=='ops'])")
[ "$n" -eq 1 ] || fail "phase 39: no denied row for the protected call"
n=$(pyq "$RT_LOG" "len([r for r in rows if r.get('call_id')=='call_OP_L2' and r.get('verdict')=='allowed'])")
[ "$n" -eq 1 ] || fail "phase 39: no allowed row for the unprotected call — the record does not show the two different verdicts"
echo "   OK no latch: in ONE pass the protected call is denied and the unprotected call is allowed — the per-call facts (and the rows derived from them) are retracted, so a denial does not leak onto the next call"

echo "== phase 40: P6 PRE-FIX CONTROL — FAIL-OPEN (the seat compiled out)"
# The SAME stream and the SAME pinned policy dir on build/fx-hostgate-noops:
# the seat does not exist, so the call crosses VERBATIM and EXECUTES.  That is
# the asymmetry — phase 39's marker-absence and rewrite are the seat's doing,
# not the scenario's — and it is the FAIL-OPEN direction the brief names.
# WHY THE CONTROL IS A MUTANT BUILD AND NOT THE PRE-CHANGE BINARY (MEASURED,
# not assumed): HEAD's tools/fx-hostgate.c has no --ops-policy-dir option at
# all, so the P3-era binary REFUSES the flag outright — `FATAL: unknown/
# incomplete argument '--ops-policy-dir'`, exit 2, NO slave path published —
# and would run none of this scenario.  The seat compiled out of the SAME
# source is therefore the only build in which the pre-seat behavior on this
# scenario can be measured, and it IS that behavior (P3's proxy).
ops_guest_arm "$GATENOOPS" "$TMP/ops-protected.sse" noops "$OPS_DIR"
[ "$OG_RC" -eq 0 ] || fail "phase 40: the pre-fix control run rc=$OG_RC (it must start AND serve)"
grep -qF "SEAT COMPILED OUT (FH_MUTANT_NO_OPS_SEAT)" "$OG_ERR" \
    || fail "phase 40: the build does not say the seat is compiled out — it is not the control this arm needs"
[ -f "$OG_MW" ] \
    || fail "phase 40: the pre-fix control did NOT execute the call the policy denies — the arm does not reproduce the fail-open and proves nothing"
n=$(pyq "$OG_TR" "len([1 for r in rows for tc in (r.get('tool_calls') or []) if tc.get('name')=='fx_write'])")
[ "$n" -ge 1 ] || fail "phase 40: the true name never reached the guest in the control — the flip is not measured on the same axis"
n=$(pyq "$OG_LOG" "len([r for r in rows for k in ('verdict','author','allow_scope','refusal_name','reason','denial_text') if k in r])")
[ "$n" -eq 0 ] || fail "phase 40: the control's log claims a verdict — no policy ran at that seat, so a verdict field is a claim wider than the evidence"
echo "   OK pre-fix fail-open: with the seat compiled out the SAME pinned policy denies nothing — the call crosses, EXECUTES (marker PRESENT) and the log carries no verdict field"

echo "== phase 41: P6 THE D2 BOUND IS ASSERTED — the host does NOT deny what only D2 would deny"
# /fx/disk/agent-data is the Agentdata row: class Datadir, protected=NO, so D1
# cannot fire; D2 would deny it ONLY on a non-ok boot verdict — live in-guest
# state this seat cannot see.  So the host seat must ALLOW it (and the guest
# floor is what governs).  Asserted BOTH ways: the real build allows and the
# call EXECUTES; the bound-unseen control DENIES the same bytes.
mkdir -p "$TMP/p6-d2"
ops_stream "$TMP/ops-data.sse" fx_write "/fx/disk/agent-data" call_OP_0002
ops_guest_arm "$GATE" "$TMP/ops-data.sse" d2data "$OPS_DIR"
[ "$OG_RC" -eq 0 ] || { sed -n '1,10p' "$OG_ERR" >&2; fail "phase 41: the unprotected-write run rc=$OG_RC"; }
[ -f "$OG_MW" ] \
    || fail "phase 41: the host seat DENIED a write only D2 could refuse (marker ABSENT) — the seat is enforcing in-guest state it cannot see"
n=$(pyq "$OG_TR" "len([1 for r in rows for tc in (r.get('tool_calls') or []) if tc.get('name')=='fx_write'])")
[ "$n" -ge 1 ] || fail "phase 41: the call did not cross as fx_write — the arm is not measuring the allowed direction"
n=$(pyq "$OG_LOG" "len([r for r in rows if r.get('call_id')=='call_OP_0002' and r.get('verdict')=='allowed' and r.get('author')=='ops'])")
[ "$n" -ge 1 ] || fail "phase 41: no allowed row naming author=ops — the record does not say which author ran and did not refuse"
# THE ALLOW CARRIES ITS OWN READING (P6-fix).  The qualifier used to live ONLY
# in the startup line, which is TRANSIENT: the one log is what a reader sees
# AT REST (fx-audit today, P9's join next), and a bare
# {"verdict":"allowed","author":"ops"} row for a D2-bound write IS "the host
# permitted this write" to anyone who does not know this seat has no floor.
# So the honesty property is ASSERTED on the record, not documented in prose.
n=$(pyq "$OG_LOG" "len([r for r in rows if r.get('call_id')=='call_OP_0002' and r.get('verdict')=='allowed' and r.get('author')=='ops' and isinstance(r.get('allow_scope'),str) and 'no operator denial at this seat' in r.get('allow_scope') and 'floor' in r.get('allow_scope')])")
[ "$n" -ge 1 ] || { sed -n '1,3p' "$OG_LOG" >&2; fail "phase 41: the D2-bound allowed row carries NO seat-scoped allow_scope qualifier — the durable record reads as a permission this seat never grants"; }
# and it is NOT smuggled into reason: an allowed row's reason stays null (the
# field is the denial's), which is why allow_scope is a NEW key.
n=$(pyq "$OG_LOG" "len([r for r in rows if r.get('call_id')=='call_OP_0002' and r.get('verdict')=='allowed' and (r.get('reason') is not None or r.get('refusal_name') is not None or r.get('denial_text') is not None)])")
[ "$n" -eq 0 ] || fail "phase 41: the allowed row's reason/refusal_name/denial_text are not null — the qualifier must not turn an allow into a refusal"
n=$(pyq "$OG_LOG" "len([1 for r in rows if r.get('call_id')=='call_OP_0002' and r.get('verdict')=='denied'])")
[ "$n" -eq 0 ] || fail "phase 41: the call was denied at the host seat"
echo "   OK D2 bound (host): an unprotected write is ALLOWED at this seat and EXECUTES, with an allowed row naming the ops author"
# THE ASYMMETRY: the bound-unseen control injects writable(<path>) — the floor
# fact this seat cannot see — so D2 fires and the SAME bytes are DENIED.  The
# bound is therefore the seat's BINDING, not the fixture's.
proxy_roundtrip "$GATEOPSFLOOR" "$TMP/ops-data.sse" opsfloor --ops-policy-dir "$OPS_DIR"
[ "$RT_RC" -eq 0 ] || fail "phase 41: the bound-unseen control exited rc=$RT_RC"
grep -qF "FH_MUTANT_OPS_BIND_UNSEEN" "$RT_ERR" \
    || fail "phase 41: the control does not say it binds the floor fact it cannot see"
grep -q 'fx_host_denied' "$RT_CAP" \
    || fail "phase 41: the bound-unseen control did NOT deny the unprotected write — D2's inertness at the real seat is not caused by the seat's binding"
grep -q 'fx_write' "$RT_CAP" && fail "phase 41: the control served the true name anyway"
n=$(pyq "$RT_LOG" "len([r for r in rows if r.get('call_id')=='call_OP_0002' and r.get('verdict')=='denied' and r.get('author')=='ops' and 'rule D2' in (r.get('reason') or '')])")
[ "$n" -ge 1 ] || fail "phase 41: the control's denial is not attributed to rule D2"
echo "   OK D2 bound (control): binding the unseen floor fact flips the SAME bytes to denied-by-ops rule D2 — the bound is the seat's binding"
# THE IN-GUEST HALF, where it is measurable: the demoted C seat, over the REAL
# verbs server, refuses the SAME path under the SAME pinned policy because the
# boot verdict is not ok.  Skipped LOUDLY without build/fx-verbs-server (a
# substitute would measure a substitute; phase 36's discipline).
if [ ! -x "$ROOT/build/fx-verbs-server" ]; then
    echo "   SKIP phase 41 (in-guest half): build/fx-verbs-server is not built — the REAL in-guest seat is the only oracle for D2 and no stand-in may replace it"
else
mkdir -p "$TMP/p6-inguest/root/usr/fx-agent/policy" "$TMP/p6-inguest/run/fx"
cp "$OPS_DIR"/ops-policy.dl "$OPS_DIR"/ops-aliases.tsv "$OPS_DIR"/ops-lexicon.ini \
   "$OPS_DIR"/PINS "$TMP/p6-inguest/root/usr/fx-agent/policy/"
python3 - "$ROOT" "$TMP/p6-inguest" <<'PY'
import json, os, subprocess, sys
root, tmp = sys.argv[1], sys.argv[2]
server = os.path.join(root, "build", "fx-verbs-server")
env = dict(os.environ)
env["FX_VERB_ROOT"] = os.path.join(tmp, "root")
env["FX_RUN"] = os.path.join(tmp, "run/fx")
# BOTH wired paths must be served: the protected alias must match a served
# path or the C seat refuses to start (its own startup obligation).
env["FX_AGENT_WRITABLE"] = "/fx/disk/agent-config.dhall:/fx/disk/agent-data"
env["PATH"] = "/usr/bin:/bin"
env.pop("FX_AGENT_BUILDABLE", None)

def call(name, args):
    inp = json.dumps({"jsonrpc": "2.0", "id": 0, "method": "initialize",
                      "params": {"protocolVersion": "2025-06-18",
                                 "capabilities": {},
                                 "clientInfo": {"name": "p6", "version": "0"}}}) + "\n"
    inp += json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                       "params": {"name": name, "arguments": args}}) + "\n"
    p = subprocess.run([server], input=inp, capture_output=True, text=True,
                       env=env, timeout=60)
    reps = [json.loads(l) for l in p.stdout.splitlines() if l.strip()]
    r = [x for x in reps if x.get("id") == 1]
    assert len(r) == 1, (name, p.stdout[:300], p.stderr[:300])
    return json.dumps(r[0])

# the SAME path the host seat ALLOWED, at the in-guest seat with no bootlog
# (an absent boot verdict -> D2 fails closed)
d2 = call("fx_write", {"path": "/fx/disk/agent-data", "content": "x"})
assert "operator policy denies this write" in d2 and "rule D2" in d2, d2[:400]
# the control: the protected path is refused by D1 here too
d1 = call("fx_write", {"path": "/fx/disk/agent-config.dhall", "content": "x"})
assert "rule D1" in d1, d1[:400]
print("in-guest seat: the path the HOST allowed is DENIED in-guest by rule D2 "
      "(boot verdict absent), and the protected path by D1")
PY
rc=$?
[ "$rc" -eq 0 ] || fail "phase 41 (in-guest half): the demoted C seat did not deny the same path by D2 (rc=$rc) — the host's silence is then not attributable to the D2 bound"
echo "   OK D2 bound (in-guest half): the SAME path the host seat allows is refused by the in-guest seat's D2 — the rule is real, it is simply not evaluable at the host seat"
fi

echo "== phase 42: P6 THE TWO-FORM ALIAS GRAMMAR, RE-RUN AT THE NEW SEAT"
# THE CASE A PREVIOUS REVIEW CAUGHT: a pattern that LOOKS protective but is
# not one of the two stated forms.  The pin-time checker refuses it, and the
# seat must refuse it TOO (it does not trust the staging) — a seat that
# accepted it would protect nothing while the artifact says it does.  The copy
# is RE-PINNED first, so the arm tests the grammar and not the pin.
cp -r "$OPS_DIR" "$TMP/p6-ambig"
sed -e 's@^Agentdata	Datadir	no	/fx/disk/agent-data$@Agentdata	Datadir	no	/fx/disk/agent-data/*@' \
    "$TMP/p6-ambig/ops-aliases.tsv" > "$TMP/p6-ambig/tsv.new"
cmp -s "$TMP/p6-ambig/ops-aliases.tsv" "$TMP/p6-ambig/tsv.new" \
    && fail "phase 42: the ambiguous-pattern sed matched NOTHING (the mutant would be the original)"
mv "$TMP/p6-ambig/tsv.new" "$TMP/p6-ambig/ops-aliases.tsv"
ops_repin "$TMP/p6-ambig"
mkdir -p "$TMP/p6-ambig-run"
timeout 10 "$GATE" --upstream "$TMP/upstream2.sse" --slave-file "$TMP/p6-ambig-run/slave" \
    --log "$TMP/p6-ambig-run/log.jsonl" --ops-policy-dir "$TMP/p6-ambig" --turns 1 \
    2> "$TMP/p6-ambig-run/err"
rc=$?
[ "$rc" -ne 0 ] || fail "phase 42: the seat STARTED with an ambiguous glob pattern (a re-pinned table) — the grammar is not enforced at the new seat"
[ ! -e "$TMP/p6-ambig-run/slave" ] || fail "phase 42: the slave path was published before the refusal"
grep -qF "/fx/disk/agent-data/*" "$TMP/p6-ambig-run/err" \
    || { sed -n '1,4p' "$TMP/p6-ambig-run/err" >&2; fail "phase 42: the refusal does not NAME the offending pattern"; }
grep -qF "silent allow-all" "$TMP/p6-ambig-run/err" \
    || fail "phase 42: the refusal does not name the failure direction"
echo "   OK ambiguous pattern: refused at the NEW seat, by name, before the slave path (re-pinned, so the pin was not what refused it)"
# THE SUBTREE FORM vs THE EXACT FORM, at the new seat: '<path>/**' covers the
# node and its descendants; a bare directory path is EXACT and covers the NODE
# ONLY.  Both directions are executed with the private pin discipline, and the
# grandchild is the discriminator (the exact-only semantics are what the S1
# review measured).
cp -r "$OPS_DIR" "$TMP/p6-subtree"
sed -e 's@^Agentdata	Datadir	no	/fx/disk/agent-data$@Agentdata	Datadir	yes	/fx/disk/agent-data/**@' \
    "$TMP/p6-subtree/ops-aliases.tsv" > "$TMP/p6-subtree/tsv.new"
cmp -s "$TMP/p6-subtree/ops-aliases.tsv" "$TMP/p6-subtree/tsv.new" \
    && fail "phase 42: the subtree sed matched NOTHING"
mv "$TMP/p6-subtree/tsv.new" "$TMP/p6-subtree/ops-aliases.tsv"
ops_repin "$TMP/p6-subtree"
ops_stream "$TMP/ops-grandchild.sse" fx_write "/fx/disk/agent-data/sub/deep/file" call_OP_0003
proxy_roundtrip "$GATE" "$TMP/ops-grandchild.sse" subtree --ops-policy-dir "$TMP/p6-subtree"
[ "$RT_RC" -eq 0 ] || fail "phase 42: the subtree arm exited rc=$RT_RC"
grep -q 'fx_host_denied' "$RT_CAP" \
    || fail "phase 42: the /** subtree form did NOT deny a grandchild at the new seat — the form is not implemented as stated"
grep -q 'fx_write' "$RT_CAP" && fail "phase 42: the true name crossed under the subtree form"
proxy_roundtrip "$GATE" "$TMP/ops-grandchild.sse" baredir --ops-policy-dir "$OPS_DIR"
[ "$RT_RC" -eq 0 ] || fail "phase 42: the exact-form arm exited rc=$RT_RC"
grep -q 'fx_write' "$RT_CAP" \
    || fail "phase 42: the EXACT (bare-directory) row denied a grandchild — glob-less patterns are NOT prefixes; this arm pins exact-only semantics at the new seat"
grep -q 'fx_host_denied' "$RT_CAP" && fail "phase 42: the exact-form row rewrote a grandchild the artifact does not cover"
n=$(pyq "$RT_LOG" "len([r for r in rows if r.get('call_id')=='call_OP_0003' and r.get('verdict')=='allowed'])")
[ "$n" -eq 1 ] || fail "phase 42: the exact-form arm did not record an allowed row"
echo "   OK subtree vs exact at the new seat: '<path>/**' denies the grandchild, a bare directory row does not (exact, never a prefix)"
# THE PIN, re-run at the new seat: a tampered artifact must fail LOUDLY.  The
# PINS row is corrupted (the artifact bytes are the same), so the refusal must
# name BOTH shas.
cp -r "$OPS_DIR" "$TMP/p6-stale"
sed -e 's@^ops-policy.dl	.*@ops-policy.dl	0000000000000000000000000000000000000000000000000000000000000000@' \
    "$TMP/p6-stale/PINS" > "$TMP/p6-stale/PINS.new"
cmp -s "$TMP/p6-stale/PINS" "$TMP/p6-stale/PINS.new" && fail "phase 42: the pin sed matched NOTHING"
mv "$TMP/p6-stale/PINS.new" "$TMP/p6-stale/PINS"
timeout 10 "$GATE" --upstream "$TMP/upstream2.sse" --slave-file "$TMP/p6-stale/slave" \
    --log "$TMP/p6-stale/log.jsonl" --ops-policy-dir "$TMP/p6-stale" --turns 1 \
    2> "$TMP/p6-stale/err"
rc=$?
[ "$rc" -ne 0 ] || fail "phase 42: the seat STARTED with a stale pin — a swapped artifact would be believed"
[ ! -e "$TMP/p6-stale/slave" ] || fail "phase 42: the slave path was published before the pin refusal"
grep -qF "sha256 mismatch: pinned 0000" "$TMP/p6-stale/err" \
    || { sed -n '1,4p' "$TMP/p6-stale/err" >&2; fail "phase 42: the pin refusal does not name both shas"; }
echo "   OK pin at the new seat: a tampered pinned artifact refuses at startup, naming both shas, before the slave path"

echo "== phase 43: P6 THE PATH CANONICALIZATION — the port that a raw match would miss"
# THE IN-GUEST SEAT CANONICALIZES the request path before matching the pinned
# patterns (canon_root_rel + ops_abs_of).  A host seat doing a RAW string
# match would miss every equivalent spelling of a protected path — the TRUE
# NAME would cross and the guest would dispatch it.  Nothing would EXECUTE
# (the in-guest floor and D1 still refuse the write at the commit site), but
# the host's own decision would be wrong, so the port is gated.
ops_stream "$TMP/ops-dotdot.sse" fx_write "/fx/disk/agent-data/../agent-config.dhall" call_OP_0004
proxy_roundtrip "$GATE" "$TMP/ops-dotdot.sse" dotdot --ops-policy-dir "$OPS_DIR"
[ "$RT_RC" -eq 0 ] || fail "phase 43: the real build exited rc=$RT_RC"
grep -q 'fx_host_denied' "$RT_CAP" \
    || fail "phase 43: an equivalent spelling of the PROTECTED path was NOT denied — the seat does not canonicalize"
grep -q 'fx_write' "$RT_CAP" && fail "phase 43: the true name crossed for a canonicalization-equivalent spelling of a protected path"
n=$(pyq "$RT_LOG" "len([r for r in rows if r.get('call_id')=='call_OP_0004' and r.get('verdict')=='denied' and r.get('author')=='ops' and '/fx/disk/agent-config.dhall' in (r.get('reason') or '')])")
[ "$n" -ge 1 ] || fail "phase 43: the denial does not quote the CANONICAL path the rule matched"
echo "   OK canonicalization: a \"..\"-spelled protected path is denied, and the row quotes the canonical path"
proxy_roundtrip "$GATEOPSNOCANON" "$TMP/ops-dotdot.sse" noconon --ops-policy-dir "$OPS_DIR"
[ "$RT_RC" -eq 0 ] || fail "phase 43: the canonicalization-blind build exited rc=$RT_RC"
grep -qF "FH_MUTANT_OPS_NO_CANON" "$RT_ERR" \
    || fail "phase 43: the blind build does not say it matches the raw path"
grep -q 'fx_write' "$RT_CAP" \
    || fail "phase 43: the raw-match control DID deny the equivalent spelling — the canonicalization is not what decides this arm"
grep -q 'fx_host_denied' "$RT_CAP" && fail "phase 43: the raw-match control still rewrote the call"
echo "   OK canonicalization asymmetry: the SAME bytes are DENIED by the seat that normalizes and CROSS on the raw-match build — the port is load-bearing, not stylistic"


echo "== phase 44: P6 THE LOADED-BUT-INERT BRANCH — a D2-only policy makes NO claim (P6-fix)"
# THE BRANCH THE CODE HANDLES BUT NO ARM PINNED (the review's nice-to-have 2).
# The seat loads the WHOLE artifact and classifies each rule LIVE or INERT
# here; a policy whose EVERY rule needs facts this seat never injects has NO
# host-side contribution, and the honesty rule says such a seat must claim
# none: OPS.present=0 -> ops_seat_present()=0 -> policy_armed() false -> NO
# verdict field on any row and NO ops author named.  A classification
# regression that silently flipped an inert policy to LIVE would render
# allowed/author=ops rows for a policy this seat cannot enforce and nothing
# would fail — that is the direction this arm exists to catch.
# THE CAUSE VARIED IS THE RULE SET, not the build or the scenario: D1's line
# is dropped from a COPY (never the pinned artifact), re-pinned with the
# private pin discipline so the pin is not what refuses, and the SAME binary
# on the SAME call with the FULL pinned policy still DENIES it (the control
# arm below, and phase 39's guest arm).
cp -r "$OPS_DIR" "$TMP/p6-inert"
grep -vF 'denied(W1, P1) :- touches(W1, P1), kind(W1, write), class(P1, C1), protected(C1).' \
    "$TMP/p6-inert/ops-policy.dl" > "$TMP/p6-inert/dl.new"
cmp -s "$TMP/p6-inert/ops-policy.dl" "$TMP/p6-inert/dl.new" \
    && fail "phase 44: the D1-drop matched NOTHING (the mutant would be the original artifact)"
mv "$TMP/p6-inert/dl.new" "$TMP/p6-inert/ops-policy.dl"
n=$(grep -c '^denied(' "$TMP/p6-inert/ops-policy.dl")
[ "$n" -eq 1 ] || fail "phase 44: the D2-only copy carries $n rule(s), not the one D2 rule"
ops_repin "$TMP/p6-inert"
# (a) the SAME call and the SAME guest/slave harness as phase 39, D2-only dir
ops_guest_arm "$GATE" "$TMP/ops-protected.sse" inert "$TMP/p6-inert"
[ "$OG_RC" -eq 0 ] || { sed -n '1,10p' "$OG_ERR" >&2; fail "phase 44: the D2-only run rc=$OG_RC"; }
grep -qF "LOADED-BUT-INERT" "$OG_ERR" \
    || { sed -n '1,8p' "$OG_ERR" >&2; fail "phase 44: the startup line does not name the loaded-but-inert state"; }
grep -qF "0 LIVE at this seat" "$OG_ERR" \
    || fail "phase 44: the startup line does not say NO rule is live at this seat"
grep -qF "NONE live at this seat" "$OG_ERR" \
    || fail "phase 44: the seat does not state that an all-inert policy gives it nothing to enforce"
grep -qF "the operator author does NOT act at this seat" "$OG_ERR" \
    || fail "phase 44: the seat does not refuse the ops-author claim for an all-inert policy"
# AND IT MAKES NO CLAIM IT CANNOT BACK: the LIVE/INERT/FLOOR block belongs to a
# seat with a live rule and must be ABSENT here (a seat that printed "LIVE AT
# THIS SEAT (D1)" over a policy with 0 live rules would be the startup-line
# version of the same over-claim).
grep -qF "LIVE AT THIS SEAT" "$OG_ERR" \
    && fail "phase 44: the seat claims a LIVE rule for a policy with none — the startup line over-claims"
grep -qF "THE FLOOR" "$OG_ERR" \
    && fail "phase 44: the seat states a floor position for a policy it does not act on"
# (b) the CALL: with no live rule the protected path is NOT the seat's to refuse
n=$(pyq "$OG_TR" "len([1 for r in rows for tc in (r.get('tool_calls') or []) if tc.get('name')=='fx_write'])")
[ "$n" -ge 1 ] || fail "phase 44: the true name fx_write did not cross under the D2-only policy — the inert seat rewrote a call it cannot judge"
n=$(pyq "$OG_TR" "len([1 for r in rows for tc in (r.get('tool_calls') or []) if tc.get('name')=='fx_host_denied'])")
[ "$n" -eq 0 ] || fail "phase 44: the inert seat denied the protected call (fx_host_denied crossed)"
[ -f "$OG_MW" ] \
    || fail "phase 44: the call did NOT execute under the D2-only policy — the arm is not measuring an ALLOW"
# (c) THE RECORD MAKES NO VERDICT CLAIM: not a denial, not an allowed row with
# an ops author, and not the allow qualifier either — no policy acted here.
n=$(pyq "$OG_LOG" "len([r for r in rows for k in ('verdict','author','allow_scope','refusal_name','reason','denial_text') if k in r])")
[ "$n" -eq 0 ] || { sed -n '1,3p' "$OG_LOG" >&2; fail "phase 44: the D2-only policy's log carries $n verdict field(s) — the record claims an author that did not act"; }
echo "   OK loaded-but-inert: a D2-only policy names NONE live, prints no LIVE/FLOOR block, makes NO verdict claim in the record, and the protected call crosses and EXECUTES"
# (d) THE ATTRIBUTION, in this phase: the SAME bytes and the SAME binary with
# the FULL pinned policy are DENIED (proxy-level, so the flip is on the rule
# set alone — phase 39 makes the same point through the real guest).
proxy_roundtrip "$GATE" "$TMP/ops-protected.sse" inert-on --ops-policy-dir "$TMP/p6-inert"
[ "$RT_RC" -eq 0 ] || fail "phase 44: the D2-only roundtrip exited rc=$RT_RC"
grep -q 'fx_write' "$RT_CAP" || fail "phase 44: the D2-only seat did not serve the call verbatim"
grep -q 'fx_host_denied' "$RT_CAP" && fail "phase 44: the D2-only seat rewrote the call — an inert policy must not deny"
n=$(pyq "$RT_LOG" "len([r for r in rows for k in ('verdict','author','allow_scope','refusal_name','reason','denial_text') if k in r])")
[ "$n" -eq 0 ] || fail "phase 44: the D2-only roundtrip's log carries $n verdict field(s)"
proxy_roundtrip "$GATE" "$TMP/ops-protected.sse" inert-off --ops-policy-dir "$OPS_DIR"
[ "$RT_RC" -eq 0 ] || fail "phase 44: the pinned-policy control roundtrip exited rc=$RT_RC"
grep -q 'fx_host_denied' "$RT_CAP" \
    || fail "phase 44: the SAME bytes under the FULL pinned policy were NOT denied — the inert arm is not attributable to the rule set"
grep -q 'fx_write' "$RT_CAP" && fail "phase 44: the pinned-policy control served the true name"
echo "   OK inert-policy asymmetry: SAME binary, SAME bytes — the FULL pinned policy denies (fx_host_denied), the D2-only policy crosses verbatim: the varied cause is the rule set"
# (e) AND THE ALLOW QUALIFIER IS NOT A REFUSAL'S FIELD: the pinned-policy
# control's denied row carries the qualifier NEVER (it is an ALLOWED-row key),
# so a reader cannot confuse the two shapes.
n=$(pyq "$RT_LOG" "len([r for r in rows if r.get('verdict')=='denied' and 'allow_scope' in r])")
[ "$n" -eq 0 ] || fail "phase 44: a DENIED row carries allow_scope — the allow qualifier leaked onto the denial shape"


echo "PASS hostgate: the transparent proxy is stream-transparent (arm == control) and a mangling proxy is caught; the per-turn open/close mechanics hold through one proxy process; the one log JOINS every answered call by call_id and REPORTS every call it could not join; a join compiled out flips the pass by content; every model-controlled free-text field arrives MARKED while the join key renders verbatim; the DECODE GATE holds the channel invariant for a denied call (the true name never crosses) in the presence of interleaves, duplicate/never-opened dones, open-at-completed items and over-cap streams, with a pinned pre-fix control for each; the RESERVED NAME is a CHECKED property (it passes the guest's charset, collides with no verb of a catalog pinned by sha256 and cross-checked against the verbs server's own table, and the proxy REFUSES TO START on a collision — while the same source with the check compiled out starts and DISPATCHES the colliding name: the silent allow); and the JUSTIFICATION is required in the injected tools schema, judged on the argument accumulator the guest actually dispatches (a done-args-only judge is pinned and caught), denied BY NAME through the existing substitution on the outbound leg, and REPORTED BY A DENIAL-RATE INSTRUMENT whose own compiled-out mutant leaves the dead-agent shape invisible; and THE OPERATOR IS A REAL AUTHOR AT THIS SEAT (P6: the pinned ops policy, its PINS check, its alias table with the TWO-FORM grammar re-run here, and its per-call fact injection with the path canonicalized before matching) with the D1/D2 split NAMED in the startup line — D1 evaluated here, D2 and the compiled-in FLOOR enforced IN-GUEST ONLY because this seat can see neither — the D2 bound ASSERTED in both directions, the ALLOWED row carrying its own seat-scoped allow_scope qualifier (so a durable record cannot read as a permission the seat never grants) with the LOADED-BUT-INERT branch pinned by its own D2-only arm, and the seat's three failure directions each pinned against a control of the SAME source (fail-open when the seat is compiled out, over-deny when it binds the floor it cannot see, silent allow when it matches the raw path)"
