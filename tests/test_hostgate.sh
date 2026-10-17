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
GATENOCLAIM="$ROOT/build/fx-hostgate-noclaim"        # the claim seat compiled out (P7 PRE-FIX control, fail-open)
GATENOEVALPIN="$ROOT/build/fx-hostgate-noevalpin"    # P7-fix PRE-FIX control: the evaluator exempt from the pin
GATENOBOUND="$ROOT/build/fx-hostgate-nobound"        # P7-fix PRE-FIX control: NO deadline on the per-call evaluator
GATENOLOGLOAD="$ROOT/build/fx-hostgate-nologload"    # P8 PRE-FIX control: the startup log load compiled out (the WIPE)
# P8-fix: three PRE-FIX CONTROLS for the P8 review's should-fixes, each the
# SAME source with one behaviour compiled out.
GATELOADUNB="$ROOT/build/fx-hostgate-loadunbound"    # R1: the LOAD-time bound compiled out (a loaded row trusted verbatim)
GATENODEDUP="$ROOT/build/fx-hostgate-nodedup"        # R2: a fresh row per OBSERVATION (the inflation + the phantom)
GATENOSCOPECARRY="$ROOT/build/fx-hostgate-noscopecarry"  # R5: the carried allow_scope ignored and recomputed (the reword)
# S1 (the host-tool registry + host_time): the colliding-name pair and the
# dispatch blind, every one from the SAME source.
GATEHOSTCOLL="$ROOT/build/fx-hostgate-hostcollide"     # host tool named fx_read -> REFUSES at startup
GATEHOSTNOCOLL="$ROOT/build/fx-hostgate-nohostcoll"   # the same name with the collision check compiled out (executes)
GATENOEXEC="$ROOT/build/fx-hostgate-noexec"           # the allowed-path registry lookup compiled out (silent degradation)
# S2 (the judged arguments + the totality check): the class-resolution blind
# (FH_MUTANT_OPS_NO_CLASS) — the plan's risk #1 made concrete: a host path
# that matched no class row, or a protected path whose class was never
# injected, EXECUTES where the real build refuses.
GATEOPSNOCLASS="$ROOT/build/fx-hostgate-opsnoclass"
# S2-FIX (the S2 review's findings): the executor hardening compiled out (a
# plain O_RDONLY open: a data-classed symlink reads a protected file, a FIFO
# blocks the lane), the judge's hardcoded "path" key, and the ONE registry
# table plus an entry that declares a read and NO classed argument key.
GATENOPLAINFILE="$ROOT/build/fx-hostgate-noplainfile"
GATEOPSLITKEY="$ROOT/build/fx-hostgate-opslitkey"
GATEEXTRAUNCL="$ROOT/build/fx-hostgate-extrauncl"
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
         "$GATENOOPS" "$GATEOPSFLOOR" "$GATEOPSNOCANON" "$GATENOCLAIM" \
         "$GATENOEVALPIN" "$GATENOBOUND" "$GATENOLOGLOAD" \
         "$GATELOADUNB" "$GATENODEDUP" "$GATENOSCOPECARRY" \
         "$GATEHOSTCOLL" "$GATEHOSTNOCOLL" "$GATENOEXEC" "$GATEOPSNOCLASS" \
         "$GATENOPLAINFILE" "$GATEOPSLITKEY" "$GATEEXTRAUNCL"; do
    [ -x "$b" ] || fail "phase 0: $b missing — run make first"
done
[ -f "$FIX/responses_simple.sse" ] || fail "phase 0: fixture $FIX/responses_simple.sse missing"
[ -f "$FIX/responses_tool.sse" ] || fail "phase 0: fixture $FIX/responses_tool.sse missing"
[ -f "$FIX/responses_interleaved.sse" ] || fail "phase 0: fixture $FIX/responses_interleaved.sse missing"
[ -f "$FIX/responses_sequential.sse" ] || fail "phase 0: fixture $FIX/responses_sequential.sse missing"
[ -f "$FIX/responses_justified.sse" ] || fail "phase 0: fixture $FIX/responses_justified.sse missing"
[ -f "$FIX/responses_host_time.sse" ] || fail "phase 0: fixture $FIX/responses_host_time.sse missing"

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

# capture_frame <slave-path> <outfile> — drive_frame PLUS a CAPTURE of every
# byte the proxy SERVED, i.e. the raw stream exactly as the guest reads it.
# This is the instrument for the P10-fix header-strip property: the guest's
# stream must not begin with an HTTP status line.  It also terminates on a
# FAILED turn (the proxy's exit closes the master -> the reader gets EIO), and
# it gives up after 5s of silence, so a proxy that serves nothing cannot hang
# the gate (closing the device is the proxy's own turn-end cue).
capture_frame() {
    python3 - "$1" "$2" <<'PY'
import json, os, select, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_APPEND)
out = open(sys.argv[2], 'wb')
frame = json.dumps({"model": "m", "stream": True,
                    "input": [{"type": "message", "role": "user", "content": "hi"}]})
os.write(fd, f"{len(frame)}\n{frame}".encode())
deadline, idle = time.time() + 30, 0
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 1)
    if not r:
        idle += 1
        if idle >= 5:
            break
        continue
    idle = 0
    try:
        b = os.read(fd, 65536)
    except OSError:
        break  # the master closed: EOF, as the guest sees it
    if not b:
        break
    out.write(b)
    if b.count(b"response.completed"):
        break
out.close()
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
# every turn, so turn 2 decodes the SAME call_id again.
#
# P8-fix (R2) CHANGED WHAT THIS PHASE PINS, DELIBERATELY AND WITH THE REASON
# STATED: it used to assert TWO rows for the one call_id ("one per turn's
# decode") with the second "legitimately pending" and NAMED UNRESOLVED by the
# exit report.  The P8 review measured that same shape in phase 59 — three
# rows for one guest-side tool call and a phantom unresolved entry at every
# exit — as a DEFECT, and it is the same defect here.  ONE call_id IS ONE
# CALL: a re-serve by the upstream is a REPEAT, not a second call, so the row
# is written once, a repeat neither re-opens nor un-answers it, and the exit
# report names nothing.  The arm is otherwise unchanged (same fixture, same
# two real turns, same guest), so the new asserts are the same measurements
# against the same wire.
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
[ "$n" -eq 1 ] || fail "phase 5: expected exactly 1 row for $CALLID (ONE ROW PER call_id — the upstream re-serves the same call every turn and a re-serve is a REPEAT of that call, not a second one; the pre-P8-fix semantics inflated it to one row per DECODE), got $n"
n=$(pyq "$L" "len([r for r in rows if r.get('call_id')=='$CALLID' and r.get('pending') is False])")
[ "$n" -eq 1 ] || fail "phase 5: expected exactly 1 RESOLVED row for $CALLID, got $n — THE JOIN DID NOT FIRE (the positive half)"
n=$(pyq "$L" "len([r for r in rows if r.get('call_id')=='$CALLID' and r.get('pending') is False and r.get('turn')==1 and isinstance(r.get('outcome'),str) and 'stub-ok' in r['outcome']])")
[ "$n" -eq 1 ] || fail "phase 5: the resolved row is not turn 1 with a stub-ok outcome — the join fired on the wrong leg"
n=$(pyq "$L" "len([r for r in rows if r.get('call_id')=='$CALLID' and r.get('args')=='{\"city\": \"Paris\"}'])")
[ "$n" -eq 1 ] || fail "phase 5: the decoded row does not carry the call's arguments verbatim"
n=$(pyq "$L" "len([r for r in rows if r.get('call_id')=='$CALLID' and r.get('session') is None and r.get('run') is None])")
[ "$n" -eq 1 ] || fail "phase 5: session/run must be explicit nulls (the wire carries no identity — do not let them silently grow values)"
# THE P8-fix HALF, BOTH DIRECTIONS: the re-serve is SAID OUT LOUD (not a silent
# dedup) and it leaves NO PHANTOM — no unresolved entry for a call that was
# answered, on stderr or in the exit row.
n=$(pyq "$L" "len([r for r in rows if r.get('type')=='proxy-exit' and any(u.get('call_id')=='$CALLID' for u in r.get('unresolved',[]))])")
[ "$n" -eq 0 ] || fail "phase 5: the exit row reports $CALLID UNRESOLVED — the call was ANSWERED by turn 2's function_call_output, so a pending entry here is the PHANTOM the review measured (a re-serve must not un-answer a call)"
grep -q "ALREADY recorded" "$TMP/proxy4.err" \
    || fail "phase 5: the proxy's stderr does not report the re-served call_id — the dedup must be LOUD, not silent"
grep -q "RE-SERVED an item" "$TMP/proxy4.err" \
    || fail "phase 5: the stderr note does not say the item was RE-SERVED (the semantics the record now implements)"
n=$(grep -c "UNRESOLVED" "$TMP/proxy4.err" || true)
[ "$n" = "0" ] || fail "phase 5: the stderr still reports an unresolved call ($n line(s)) after a cleanly answered two-turn run"
assert_no_policy_fields "$L"
echo "   OK positive: ONE row for the call_id, RESOLVED by turn 2's function_call_output (outcome=stub-ok, args verbatim); the re-serve is reported on stderr and leaves NO phantom unresolved entry; no row carries a verdict field"

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
# P8-fix (R2): ONE ROW PER call_id — this was 2 (one per turn's decode) before
# the re-serve was deduped; the row itself is unchanged in shape.
[ "$n" -eq 1 ] || fail "phase 12: expected 1 verdict=allowed row with NULL refusal fields (one row per call_id), got $n — the armed-policy allowed shape is wrong"
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
# S1: the injected catalog is the pinned guest verbs FOLLOWED BY the compiled-in
# host-tool registry — two closed lists, each injected from its own table, and
# the model is told which side executes (the description says so).
verbs_pinned = [v.strip() for v in open(sys.argv[2]) if v.strip()]
assert names[:len(verbs_pinned)] == verbs, f"the injected guest catalog != the pinned one: {names[:len(verbs_pinned)]} vs {verbs}"
host = names[len(verbs_pinned):]
assert host == ["host_time", "host_cat"], f"the injected host-tool entries are {host}, want exactly ['host_time', 'host_cat']"
assert "EXECUTED ON THE HOST" in tools[-1]["description"], tools[-1]["description"]
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
echo "   OK injection: the forwarded frame carries all 13 pinned verbs followed by the host-tool registry (host_time, host_cat — each whose description says the HOST executes it), each with justification REQUIRED, and the injection-compiled-out build sends none while still denying — the check the model was never told about"

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
# (a) THE SPLIT IS READ OUT OF THE ARTIFACT, not asserted from a plan: the
# rules of policy/ops/ops-policy.dl are quoted here and must appear verbatim,
# and the C seat this seat ports must be consulted from EXACTLY ONE commit
# site, inside native_write — the provenance of the pinned write-verb set.
# S2 adds D3 (the hosttool bridge), which is LIVE here too.
r1='denied(W1, P1) :- touches(W1, P1), kind(W1, write), class(P1, C1), protected(C1).'
r2='denied(W1, P1) :- touches(W1, P1), kind(W1, write), writable(P1), !boot_verdict(ok).'
r3='denied(W1, P1) :- hosttool(W1), touches(W1, P1), class(P1, C1), protected(C1).'
grep -qF "$r1" "$OPS_DIR/ops-policy.dl" \
    || fail "phase 38: the pinned artifact does not carry D1 as the rule text read here"
grep -qF "$r2" "$OPS_DIR/ops-policy.dl" \
    || fail "phase 38: the pinned artifact does not carry D2 as the rule text read here"
grep -qF "$r3" "$OPS_DIR/ops-policy.dl" \
    || fail "phase 38: the pinned artifact does not carry D3 (the S2 hosttool bridge) as the rule text read here"
n=$(grep -c '!ops_write_allowed(' "$ROOT/tools/fx-verbs-server.c")
[ "$n" -eq 1 ] || fail "phase 38: the in-guest ops seat has $n commit sites, not one — the write-verb set pinned in the proxy may be incomplete"
csite=$(grep -n '!ops_write_allowed(' "$ROOT/tools/fx-verbs-server.c" | cut -d: -f1)
ndef=$(grep -n '^static int native_write' "$ROOT/tools/fx-verbs-server.c" | cut -d: -f1)
[ -n "$ndef" ] && [ "$csite" -gt "$ndef" ] \
    || fail "phase 38: the single ops commit site is not inside native_write (def=$ndef call=$csite) — the write-verb provenance is wrong"
nxt=$(awk -v s="$ndef" 'NR>s && /^static /{print NR; exit}' "$ROOT/tools/fx-verbs-server.c")
[ "$csite" -lt "$nxt" ] || fail "phase 38: the ops commit site ($csite) is not inside native_write (which ends at $nxt)"
echo "   OK split source: the artifact's own D1/D2/D3 lines are quoted; the in-guest seat has ONE commit site, inside native_write (line $csite) — the pinned write-verb set's provenance"
# (b) the STARTUP LINE, on the real build with the real dir: it names D1+D3
# live, D2 inert WITH ITS REASON, and states the floor is in-guest only.
# Nothing is driven — the proxy is started bounded and reaped.
mkdir -p "$TMP/p6-start"
"$GATE" --upstream "$TMP/upstream2.sse" --slave-file "$TMP/p6-start/slave" \
    --log "$TMP/p6-start/log.jsonl" --ops-policy-dir "$OPS_DIR" --turns 1 \
    2> "$TMP/p6-start/err" &
P6S=$!
PROXIES="$PROXIES $P6S"
wait_for_slave "$TMP/p6-start/slave" "$P6S" "$TMP/p6-start/err"
kill "$P6S" 2>/dev/null
wait "$P6S" 2>/dev/null
for want in "2 LIVE at this seat (D1,D3)" "INERT AT THIS SEAT (D2)" \
            "boot_verdict" "never injects writable" "THE FLOOR" \
            "enforced IN-GUEST ONLY" "has NO floor of its own" "2 host tool(s) bound"; do
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
# AND S2's D3 line are dropped from a COPY (never the pinned artifact), so
# only the inert D2 remains — re-pinned with the private pin discipline so the
# pin is not what refuses, and the SAME binary on the SAME call with the FULL
# pinned policy still DENIES it (the control arm below, and phase 39's guest
# arm).
cp -r "$OPS_DIR" "$TMP/p6-inert"
grep -vF -e 'denied(W1, P1) :- touches(W1, P1), kind(W1, write), class(P1, C1), protected(C1).' \
         -e 'denied(W1, P1) :- hosttool(W1), touches(W1, P1), class(P1, C1), protected(C1).' \
    "$TMP/p6-inert/ops-policy.dl" > "$TMP/p6-inert/dl.new"
cmp -s "$TMP/p6-inert/ops-policy.dl" "$TMP/p6-inert/dl.new" \
    && fail "phase 44: the D1+D3 drop matched NOTHING (the mutant would be the original artifact)"
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



# ── P7: THE CLAIM AUTHOR at the HOST SEAT (policy/calls/, free LE, the S0 mirror) ─
# `le` and the engine are HARD deps of this slice (free LE over a closed
# lexicon IS the judgment), so their absence FAILS here rather than skipping.
SIBS="${FX_SIBLINGS:-$(cd "$ROOT/.." && pwd)}"
[ -d "$SIBS/fx-init" ] || [ -n "${FX_SIBLINGS:-}" ] || SIBS="$HOME/fixpoint-linux"
LE_ROOT="${LE_DIR:-}"
if [ -z "$LE_ROOT" ]; then
    for cand in "$SIBS/logical-english" "$ROOT/../logical-english" "$HOME/logical-english"; do
        if [ -f "$cand/le/__init__.py" ]; then LE_ROOT="$cand"; break; fi
    done
fi
[ -f "$LE_ROOT/le/__init__.py" ] || fail "phase 45: no le checkout (set LE_DIR)"
export LE_DIR="$LE_ROOT"
DLB_PY="${DLB_PATH:-}"
if [ -z "$DLB_PY" ]; then
    for cand in "$SIBS/datalog-dafsa/python" "$ROOT/../datalog-dafsa/python" "$HOME/fixpoint-linux/datalog-dafsa/python"; do
        if [ -f "$cand/dlb/__init__.py" ]; then DLB_PY="$cand"; break; fi
    done
fi
[ -f "$DLB_PY/dlb/__init__.py" ] || fail "phase 45: no dlb python binding (set DLB_PATH)"
export DLB_PATH="$DLB_PY"

CALLS_DIR="$ROOT/policy/calls"
CALLS_EVAL="$CALLS_DIR/eval_calls.py"
CALLS_LEX="$CALLS_DIR/calls-lexicon.ini"
CALLS_PLEX="$CALLS_DIR/calls-policy-lexicon.ini"
CALLS_ART="$CALLS_DIR/calls-policy.dl"
CALLS_PINS="$CALLS_DIR/PINS"
CALLS_VERBS="$CALLS_DIR/calls-verbs.tsv"
CALLS_FIX="$ROOT/tests/fixtures/calls"
OPS_EVAL="$ROOT/policy/ops/eval_ops.py"
OPS_LEX="$ROOT/policy/ops/ops-lexicon.ini"
for f in "$CALLS_EVAL" "$CALLS_LEX" "$CALLS_PLEX" "$CALLS_ART" "$CALLS_PINS" "$CALLS_VERBS" \
         "$CALLS_FIX/good.le" "$CALLS_FIX/hostile.le" "$CALLS_FIX/vacuous-unconnected.le" \
         "$CALLS_FIX/vacuous-selfloop.le" "$CALLS_FIX/premise-false.le" \
         "$CALLS_FIX/premise-selfsupport.le" "$CALLS_FIX/head-forgery.le" \
         "$CALLS_FIX/seam.le" "$CALLS_FIX/policy-vacuous.le" "$CALLS_FIX/policy-foreign-head.le" \
         "$CALLS_FIX/calls-sentence-denied.le" "$OPS_EVAL" "$OPS_LEX" \
         "$ROOT/tests/fixtures/ops/ops-sentence-justified.le"; do
    [ -f "$f" ] || fail "phase 45: missing $f"
done

# the call row (a write) and the seat facts the write call's world carries
cat > "$TMP/calls-call.tsv" <<'TSV'
CallA	Writeverb
TSV
cat > "$TMP/calls-facts.tsv" <<'TSV'
call_purpose	calla	alter
forbidden_purpose	activate
TSV
# the SAME call, but serving the FORBIDDEN purpose (fx_activate)
cat > "$TMP/calls-call-activate.tsv" <<'TSV'
CallA	Activateverb
TSV
cat > "$TMP/calls-facts-activate.tsv" <<'TSV'
call_purpose	calla	activate
forbidden_purpose	activate
TSV

# the common argument sets: PINNED (the honest arms, pin-verified) and the
# plain set for the mutant arms (whose lexicons carry a different sha).
CALLS_PINNED=(--lexicon "$CALLS_LEX" --policy "$CALLS_ART" --facts "$TMP/calls-facts.tsv" --pins "$CALLS_PINS")
CALLS_CL=(--lexicon "$CALLS_LEX" --policy "$CALLS_ART" --facts "$TMP/calls-facts.tsv")

calls_arm() { # NAME WANT_RC PATTERN ARGS...
    name=$1; want=$2; pat=$3; shift 3
    out="$TMP/calls-$name.txt"
    python3 "$CALLS_EVAL" "$@" >"$out" 2>&1
    rc=$?
    [ "$rc" = "$want" ] || fail "calls arm $name: exit $rc, expected $want; record: $(grep -m1 verdict "$out" || head -2 "$out")"
    grep -q "$pat" "$out" || fail "calls arm $name: '$pat' absent from the record ($(grep -m1 verdict "$out"))"
    echo "   OK $name (exit $rc, /$pat/)"
}

echo "== phase 45: P7 THE ARTIFACT — pin determinism, lint, verb table, the two-author boundary"
# (a) THE PIN: two compiles byte-identical; the artifact and the two lexicons
# and the verb table all match PINS.
python3 "$CALLS_EVAL" --compile-policy --policy-le "$CALLS_DIR/calls-policy.le" --policy-lexicon "$CALLS_PLEX" >"$TMP/calls-policy.1" 2>"$TMP/calls-policy.err" \
    || fail "phase 45: compiling the calls policy failed: $(cat "$TMP/calls-policy.err")"
python3 "$CALLS_EVAL" --compile-policy --policy-le "$CALLS_DIR/calls-policy.le" --policy-lexicon "$CALLS_PLEX" >"$TMP/calls-policy.2" 2>>"$TMP/calls-policy.err" \
    || fail "phase 45: the second calls policy compile failed: $(cat "$TMP/calls-policy.err")"
cmp -s "$TMP/calls-policy.1" "$TMP/calls-policy.2" || fail "phase 45: two calls policy compiles are NOT byte-identical"
grep -q '^justified(' "$TMP/calls-policy.1" || fail "phase 45: the calls artifact does not conclude justified"
cmp -s "$TMP/calls-policy.1" "$CALLS_ART" || fail "phase 45: calls-policy.dl is NOT the artifact a fresh compile produces — regenerate with 'make calls-policy-artifact' and update policy/calls/PINS in the same commit"
for pair in 'calls-policy.dl' 'calls-lexicon.ini' 'calls-policy-lexicon.ini' 'calls-verbs.tsv' 'eval_calls.py'; do
    case $pair in
        calls-policy.dl) sf=$(sha256sum "$TMP/calls-policy.1" | cut -d' ' -f1) ;;
        calls-lexicon.ini) sf=$(sha256sum "$CALLS_LEX" | cut -d' ' -f1) ;;
        calls-policy-lexicon.ini) sf=$(sha256sum "$CALLS_PLEX" | cut -d' ' -f1) ;;
        calls-verbs.tsv) sf=$(sha256sum "$CALLS_VERBS" | cut -d' ' -f1) ;;
        eval_calls.py) sf=$(sha256sum "$CALLS_EVAL" | cut -d' ' -f1) ;;
    esac
    sp=$(grep "^$pair" "$CALLS_PINS" | cut -f2)
    [ "$sf" = "$sp" ] || fail "phase 45: $pair pinned sha $sp != actual $sf — the pin and the artifact have drifted"
done
echo "   OK calls-policy pin: two compiles byte-identical; artifact + both lexicons + verb table + the EVALUATOR all match PINS"
# (b) THE LINT: the agent lexicon's boundary (no justified, no denied, the
# conclusion subset), and each reopened boundary refused by name.
calls_arm lint-lexicon-ok 0 'judgment-in-agent-lexicon=absent' --lint-lexicon "$CALLS_LEX"
sed -e 's@^\[predicates\]$@[predicates]\n<a call C> is justified | justified | call@' "$CALLS_LEX" > "$TMP/calls-mutant-lex.ini"
cmp -s "$CALLS_LEX" "$TMP/calls-mutant-lex.ini" && fail "phase 45: the lexicon sed matched NOTHING"
calls_arm lint-mutant-justified 1 'boundary-reopened' --lint-lexicon "$TMP/calls-mutant-lex.ini"
sed -e 's@^\[predicates\]$@[predicates]\n<a call C> is denied | denied | call@' "$CALLS_LEX" > "$TMP/calls-mutant-denied.ini"
cmp -s "$CALLS_LEX" "$TMP/calls-mutant-denied.ini" && fail "phase 45: the denied-seam sed matched NOTHING"
calls_arm lint-mutant-denied 1 'boundary-reopened' --lint-lexicon "$TMP/calls-mutant-denied.ini"
# (c) THE VERB TABLE (the seam bridge): validated, and an underscored
# verb-symbol (a runtime verb spelled as a proper noun) is refused LOUDLY.
calls_arm verbs-ok 0 'verb table OK' --check-verbs --verbs "$CALLS_VERBS" --policy-lexicon "$CALLS_LEX"
sed -e 's@^fx_write	Writeverb@fx_write	Write_verb@' "$CALLS_VERBS" > "$TMP/calls-verbs-seam.tsv"
cmp -s "$CALLS_VERBS" "$TMP/calls-verbs-seam.tsv" && fail "phase 45: the verbs sed matched NOTHING"
calls_arm verbs-seam-underscore 1 'verb-not-proper' --check-verbs --verbs "$TMP/calls-verbs-seam.tsv" --policy-lexicon "$CALLS_LEX"
# (c2) THE SHARE FORM (P7-fix): TWO runtime verbs mapped to ONE folded
# verb-symbol.  `verb-table-missing` catches only a symbol mapped by NONE, so
# this needs its own named refusal — the call spine is per-symbol, and one
# contention would otherwise justify BOTH runtime verbs.
awk -F'\t' 'BEGIN{OFS="\t"} {print} $1=="fx_write"{print "fx_ls","Writeverb","Inspect","no"}' \
    "$CALLS_VERBS" > "$TMP/calls-verbs-dup.tsv"
cmp -s "$CALLS_VERBS" "$TMP/calls-verbs-dup.tsv" && fail "phase 45: the verbs-dup rewrite matched NOTHING"
grep -q '^fx_ls	Writeverb' "$TMP/calls-verbs-dup.tsv" || fail "phase 45: the dup table does not carry the shared symbol"
calls_arm verbs-dup-symbol 1 'verb-symbol-duplicate' --check-verbs --verbs "$TMP/calls-verbs-dup.tsv" --policy-lexicon "$CALLS_LEX"
# (d) THE TWO-AUTHOR BOUNDARY, both directions: the calls lexicon refuses
# `denied`; the ops lexicon refuses `justified`.
calls_arm twoauthor-calls-refuses-denied 1 'sentence-foreign-predicate' \
    --compile-sentence --policy-lexicon "$CALLS_LEX" --sentence "$CALLS_FIX/calls-sentence-denied.le"
python3 "$OPS_EVAL" --compile-sentence --policy-lexicon "$OPS_LEX" --sentence "$ROOT/tests/fixtures/ops/ops-sentence-justified.le" >"$TMP/calls-ops-refuses-justified.txt" 2>&1
rc=$?
[ "$rc" = 1 ] || fail "phase 45: the ops lexicon did NOT refuse justified (rc=$rc)"
grep -q 'sentence-foreign-predicate' "$TMP/calls-ops-refuses-justified.txt" || fail "phase 45: the ops refusal is not by name"
# THE BOUNDARY IS THE CLOSURE, shown for the calls direction: add `denied` to a
# COPY of the calls lexicon and the same sentence compiles — the refusal was
# the lexicon's, not the sentence's or the tool's.
sed -e 's@^\[predicates\]$@[predicates]\n<a call C> is denied | denied | call@' "$CALLS_LEX" > "$TMP/calls-mutant-denied2.ini"
cmp -s "$CALLS_LEX" "$TMP/calls-mutant-denied2.ini" && fail "phase 45: the denied-mutant sed matched NOTHING"
python3 "$CALLS_EVAL" --compile-sentence --policy-lexicon "$TMP/calls-mutant-denied2.ini" --sentence "$CALLS_FIX/calls-sentence-denied.le" >"$TMP/calls-twoauthor-mutant.txt" 2>&1
rc=$?
[ "$rc" = 0 ] || fail "phase 45: the denied-mutant lexicon did not let the sentence compile (rc=$rc) — the closure is not what refuses it"
grep -q '^denied(' "$TMP/calls-twoauthor-mutant.txt" || fail "phase 45: the denied-mutant compile did not produce the denied rule"
echo "   OK two-author: calls refuses denied, ops refuses justified — each by le's own named gap, and adding the foreign predicate to a copy lets it compile (the closure is the boundary)"

echo "== phase 46: P7 THE BOUNDARY MUTANT (A6a/A6b) — the lexicon closure AND the head check"
# A6a: the mutant lexicon (justified declared) lets the HOSTILE justification
# compile — what refuses it now is the HEAD CHECK.
calls_arm a6a-mutant-lexicon-hostile 1 'head-forgery' \
    --call "$TMP/calls-call.tsv" --le "$CALLS_FIX/hostile.le" \
    --lexicon "$TMP/calls-mutant-lex.ini" --policy "$CALLS_ART" --facts "$TMP/calls-facts.tsv"
# A6b: THE BREACH, EXECUTED — both checks gone, the agent derives `justified`
# itself.  This is why both checks exist.
sed -e 's@if pred not in AGENT_CONCLUSIONS:@if False:@' "$CALLS_EVAL" > "$TMP/calls-mutant-eval.py"
cmp -s "$CALLS_EVAL" "$TMP/calls-mutant-eval.py" && fail "phase 46: the evaluator sed matched NOTHING"
grep -q 'if False:' "$TMP/calls-mutant-eval.py" || fail "phase 46: the evaluator mutant does not drop the head check"
python3 "$TMP/calls-mutant-eval.py" --call "$TMP/calls-call.tsv" --le "$CALLS_FIX/hostile.le" \
    --lexicon "$TMP/calls-mutant-lex.ini" --policy "$CALLS_ART" --facts "$TMP/calls-facts.tsv" >"$TMP/calls-a6b.txt" 2>&1
rc=$?
[ "$rc" = 0 ] || fail "phase 46: the double mutant did NOT derive justified (exit $rc) — the breach could not be executed"
grep -q 'verdict	derives	justified(calla)' "$TMP/calls-a6b.txt" || fail "phase 46: no derives row from the double mutant"
echo "   OK a6b-double-mutant-breach: the agent derived justified ITSELF — the breach is executable, not hypothetical"
# the honest arm stays derives under BOTH mutants (blind on exactly the hostile fixture)
calls_arm a6c-mutant-lexicon-honest 0 'verdict	derives' \
    --call "$TMP/calls-call.tsv" --le "$CALLS_FIX/good.le" \
    --lexicon "$TMP/calls-mutant-lex.ini" --policy "$CALLS_ART" --facts "$TMP/calls-facts.tsv"
python3 "$TMP/calls-mutant-eval.py" --call "$TMP/calls-call.tsv" --le "$CALLS_FIX/good.le" \
    --lexicon "$CALLS_LEX" --policy "$CALLS_ART" --facts "$TMP/calls-facts.tsv" >"$TMP/calls-a6d.txt" 2>&1
[ "$?" = 0 ] || fail "phase 46: the evaluator mutant changed the honest arm's answer"
grep -q 'verdict	derives' "$TMP/calls-a6d.txt" || fail "phase 46: no derives row (honest + eval mutant)"

echo "== phase 47: P7 VACUITY + PREMISES — four arguments that justify NOTHING"
calls_arm a-good-derives 0 'verdict	derives	justified(calla)	rows=1' \
    --call "$TMP/calls-call.tsv" --le "$CALLS_FIX/good.le" "${CALLS_PINNED[@]}"
calls_arm a-vacuous-unconnected 1 'justified-not-derived' \
    --call "$TMP/calls-call.tsv" --le "$CALLS_FIX/vacuous-unconnected.le" \
    --lexicon "$CALLS_LEX" --policy "$CALLS_ART" --facts "$TMP/calls-facts.tsv"
calls_arm a-vacuous-selfloop 1 'justified-not-derived' \
    --call "$TMP/calls-call.tsv" --le "$CALLS_FIX/vacuous-selfloop.le" \
    --lexicon "$CALLS_LEX" --policy "$CALLS_ART" --facts "$TMP/calls-facts.tsv"
calls_arm a-premise-false 1 'premise-false' \
    --call "$TMP/calls-call.tsv" --le "$CALLS_FIX/premise-false.le" \
    --lexicon "$CALLS_LEX" --policy "$CALLS_ART" --facts "$TMP/calls-facts.tsv"
calls_arm a-premise-selfsupport 1 'premise-false' \
    --call "$TMP/calls-call.tsv" --le "$CALLS_FIX/premise-selfsupport.le" \
    --lexicon "$CALLS_LEX" --policy "$CALLS_ART" --facts "$TMP/calls-facts.tsv"
calls_arm a-head-forgery 1 'head-forgery' \
    --call "$TMP/calls-call.tsv" --le "$CALLS_FIX/head-forgery.le" \
    --lexicon "$CALLS_LEX" --policy "$CALLS_ART" --facts "$TMP/calls-facts.tsv"
echo "   OK vacuity + premises: an argument that never reaches the judgment rule, or asserts a false/self-supporting premise, justifies NOTHING"

echo "== phase 48: P7 THE LETTERS-ONLY SEAM — spelling a runtime verb matches NOTHING"
# THE SILENT DIRECTION, executed: the agent spells the RUNTIME verb as a
# letters-only proper noun (Fxwrite -> fxwrite) while the seat injects the
# ABSTRACT symbol (Writeverb -> writeverb).  The contention for Fxwrite matches
# NOTHING, so the argument derives no contention for the call's real verb.
sed -e 's@^Writeverb = verb$@Writeverb = verb\nFxwrite = verb@' "$CALLS_LEX" > "$TMP/calls-seam-lex.ini"
cmp -s "$CALLS_LEX" "$TMP/calls-seam-lex.ini" && fail "phase 48: the seam lexicon sed matched NOTHING"
grep -q '^Fxwrite = verb' "$TMP/calls-seam-lex.ini" || fail "phase 48: the seam lexicon does not declare Fxwrite"
calls_arm a-seam-silent 1 'justified-not-derived' \
    --call "$TMP/calls-call.tsv" --le "$CALLS_FIX/seam.le" \
    --lexicon "$TMP/calls-seam-lex.ini" --policy "$CALLS_ART" --facts "$TMP/calls-facts.tsv"
echo "   OK seam silent: the spelled runtime verb (Fxwrite) matches nothing the seat injects — the justification cannot derive"
# the LOUD direction is already covered by phase 45's verbs-seam-underscore
# (an underscored verb-symbol is refused at pin time by name, never silently
# unmatched).

echo "== phase 49: P7 JUSTIFIED=ALLOW / NOT-JUSTIFIED=DENY, end to end on served bytes"
calls_stream() { # <dest> <name> <justification-file> <call-id> [<name> <just-file> <call-id>]...
    python3 - "$@" <<'PY'
import json, sys
dest = sys.argv[1]
triples = [tuple(sys.argv[i:i + 3]) for i in range(2, len(sys.argv), 3)]
ev = []
seq = 0
completed = []
for n, (name, jfile, cid) in enumerate(triples, start=1):
    just = open(jfile).read()
    iid = "item_CM_%d" % n
    args = json.dumps({"path": "/fx/disk/agent-data", "justification": just})
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
make_calls_stub() { # <script-path> <write-marker> <activate-marker>
    cat > "$1" <<PY
#!/usr/bin/env python3
# Two-verb dispatch-recording stub: fx_write and fx_activate each touch their
# OWN marker; anything else -> -32602 (the verbs server's unknown-name shape).
import json
import sys
MARKERS = {"fx_write": "$2", "fx_activate": "$3"}
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
            "serverInfo": {"name": "hostgate-calls-stub", "version": "0"}}}),
            flush=True)
    elif m == "tools/call":
        name = (req.get("params") or {}).get("name")
        if name in MARKERS:
            with open(MARKERS[name], "a") as f:
                f.write("dispatched %s\\n" % name)
            print(json.dumps({"jsonrpc": "2.0", "id": req.get("id"),
                              "result": {"content": [{"type": "text",
                                                      "text": "ok-" + name}]}}),
                  flush=True)
        else:
            print(json.dumps({"jsonrpc": "2.0", "id": req.get("id"),
                              "error": {"code": -32602,
                                        "message": "unknown tool: %s" % name}}),
                  flush=True)
PY
    chmod +x "$1"
}
# calls_guest_arm: the whole guest loop THROUGH the proxy with the calls stub;
# exports CC_TR CC_LOG CC_DUMP CC_ERR CC_MW CC_MA CC_RC.
calls_guest_arm() { # <gate> <upstream> <tag> <calls-dir>
    local gate="$1" upstream="$2" tag="$3" cdir="$4"
    shift 4
    local data="$TMP/calls-data-$tag"
    local cfg="$TMP/calls-cfg-$tag"
    local mw="$TMP/calls-marker-$tag-write"
    local ma="$TMP/calls-marker-$tag-activate"
    mkdir -p "$data" "$cfg"
    make_calls_stub "$TMP/calls-stub-$tag.py" "$mw" "$ma"
    cat > "$cfg/config.dhall" <<DHALL
{ agents =
  [ { name = "fx"
    , agent_type = "agent"
    , mcp_servers = [ { command = "$TMP/calls-stub-$tag.py", args = [] : List Text } ]
    }
  ]
}
DHALL
    "$gate" --upstream "$upstream" --slave-file "$TMP/calls-slave-$tag" \
        --log "$TMP/calls-log-$tag.jsonl" --dump-requests "$TMP/calls-dump-$tag.jsonl" \
        --calls-policy-dir "$cdir" --require-justification "$@" --turns 2 2> "$TMP/calls-err-$tag" &
    local p=$!
    PROXIES="$PROXIES $p"
    wait_for_slave "$TMP/calls-slave-$tag" "$p" "$TMP/calls-err-$tag"
    local dev
    dev=$(cat "$TMP/calls-slave-$tag")
    FX_CHARDEV="$dev" FX_AGENT_CONFIG_DIR="$cfg" \
    FX_AGENT_DATA="$data" HOME="$TMP" \
        "$BIN" -p "$SENTINEL" --agent fx --max-turns 2 --output text \
        > "$TMP/calls-stdout-$tag" 2> "$TMP/calls-guesterr-$tag"
    CC_RC=$?
    wait_for_proxy_exit "$p" "$TMP/calls-err-$tag"
    CC_TR=$(ls "$data"/sessions/*/messages.jsonl 2>/dev/null)
    CC_LOG="$TMP/calls-log-$tag.jsonl"
    CC_DUMP="$TMP/calls-dump-$tag.jsonl"
    CC_ERR="$TMP/calls-err-$tag"
    CC_MW="$mw"
    CC_MA="$ma"
}
# (a) JUSTIFIED: fx_write with an honest argument — the call crosses VERBATIM
# and EXECUTES, and the row names the claim author (with the justification).
calls_stream "$TMP/calls-justified.sse" fx_write "$CALLS_FIX/good.le" call_CM_0001
calls_guest_arm "$GATE" "$TMP/calls-justified.sse" justified "$CALLS_DIR"
[ "$CC_RC" -eq 0 ] || { sed -n '1,10p' "$CC_ERR" >&2; fail "phase 49: the justified run rc=$CC_RC"; }
[ -f "$CC_TR" ] || fail "phase 49: no guest transcript — the arm is not the real scenario"
n=$(pyq "$CC_TR" "len([1 for r in rows for tc in (r.get('tool_calls') or []) if tc.get('name')=='fx_write' and tc.get('id')=='call_CM_0001'])")
[ "$n" -eq 1 ] || fail "phase 49: the justified call did not cross as fx_write"
n=$(pyq "$CC_TR" "len([1 for r in rows for tc in (r.get('tool_calls') or []) if tc.get('name')=='fx_host_denied'])")
[ "$n" -eq 0 ] || fail "phase 49: the justified call was denied"
[ -f "$CC_MW" ] || fail "phase 49: the justified call did NOT execute (marker absent)"
n=$(pyq "$CC_LOG" "len([r for r in rows if r.get('call_id')=='call_CM_0001' and r.get('verdict')=='allowed' and 'claim' in (r.get('author') or '')])")
[ "$n" -ge 1 ] || { sed -n '1,3p' "$CC_LOG" >&2; fail "phase 49: no allowed row naming the claim author"; }
# P7-fix: the ALLOWED row's allow_scope names the seat that ACTED — with the
# claim author live and deriving, the qualifier must say so, not carry the P6
# operator-only text.
n=$(pyq "$CC_LOG" "len([r for r in rows if r.get('call_id')=='call_CM_0001' and r.get('verdict')=='allowed' and 'claim refusal' in (r.get('allow_scope') or '')])")
[ "$n" -ge 1 ] || { sed -n '1,3p' "$CC_LOG" >&2; fail "phase 49: the allowed row's allow_scope does not name the claim seat that acted"; }
echo "   OK justified=allow: fx_write crosses and EXECUTES; the row is verdict=allowed author includes claim, allow_scope names the claim refusal it passed"
# (b) NOT-JUSTIFIED: fx_activate serves the FORBIDDEN purpose — denied by the
# claim author, the true name never crosses, nothing executes, and the denial
# reaches the model through the existing P3 path.
calls_stream "$TMP/calls-forbidden.sse" fx_activate "$CALLS_FIX/good.le" call_CM_0002
calls_guest_arm "$GATE" "$TMP/calls-forbidden.sse" forbidden "$CALLS_DIR"
[ "$CC_RC" -eq 0 ] || { sed -n '1,10p' "$CC_ERR" >&2; fail "phase 49: the forbidden run rc=$CC_RC"; }
[ -f "$CC_TR" ] || fail "phase 49: no guest transcript for the forbidden arm"
n=$(pyq "$CC_TR" "len([1 for r in rows for tc in (r.get('tool_calls') or []) if tc.get('name')=='fx_host_denied' and tc.get('id')=='call_CM_0002'])")
[ "$n" -eq 1 ] || fail "phase 49: the forbidden call was not rewritten to fx_host_denied"
n=$(pyq "$CC_TR" "len([1 for r in rows for tc in (r.get('tool_calls') or []) if tc.get('name')=='fx_activate'])")
[ "$n" -eq 0 ] || fail "phase 49: THE TRUE NAME fx_activate reached the guest as a call name"
[ ! -e "$CC_MA" ] || fail "phase 49: the forbidden call EXECUTED (activate marker present)"
n=$(pyq "$CC_LOG" "len([r for r in rows if r.get('call_id')=='call_CM_0002' and r.get('verdict')=='denied' and r.get('author')=='claim' and r.get('refusal_name')=='denied-by-claim'])")
[ "$n" -ge 1 ] || { sed -n '1,3p' "$CC_LOG" >&2; fail "phase 49: no row naming author=claim refusal_name=denied-by-claim"; }
n=$(pyq "$CC_DUMP" "len([r for r in rows if any(i.get('type')=='function_call' and i.get('call_id')=='call_CM_0002' and i.get('name')=='fx_activate' for i in r.get('input',[]))])")
[ "$n" -ge 1 ] || fail "phase 49: the dumped outbound frame does not RESTORE the true name"
n=$(pyq "$CC_DUMP" "len([r for r in rows if any(i.get('type')=='function_call_output' and i.get('call_id')=='call_CM_0002' and isinstance(i.get('output'),str) and i['output'].startswith('(denied by host policy:') for i in r.get('input',[]))])")
[ "$n" -ge 1 ] || fail "phase 49: the denial text did not reach the model as the call's own result"
echo "   OK not-justified=deny: fx_host_denied on the wire (never fx_activate), NO dispatch, restored name + denial text on the outbound leg, row author=claim"

echo "== phase 50: P7 PRE-FIX CONTROL — FAIL-OPEN (the claim seat compiled out)"
# The SAME forbidden-purpose stream AND the SAME flags on build/fx-hostgate-
# noclaim: the claim seat does not exist, so the call crosses VERBATIM and
# EXECUTES (the justification author — still armed — allows a valid
# justification; the claim author, the ONLY thing that would deny this call, is
# gone).  The asymmetry — phase 49's rewrite and marker-absence are the seat's
# doing, not the scenario's.
calls_guest_arm "$GATENOCLAIM" "$TMP/calls-forbidden.sse" noclaim "$CALLS_DIR"
[ "$CC_RC" -eq 0 ] || fail "phase 50: the pre-fix control run rc=$CC_RC"
grep -qF "SEAT COMPILED OUT (FH_MUTANT_NO_CLAIM_SEAT)" "$CC_ERR" \
    || fail "phase 50: the build does not say the claim seat is compiled out"
[ -f "$CC_MA" ] || fail "phase 50: the pre-fix control did NOT execute the call the policy refuses — the arm does not reproduce the fail-open"
n=$(pyq "$CC_TR" "len([1 for r in rows for tc in (r.get('tool_calls') or []) if tc.get('name')=='fx_activate'])")
[ "$n" -ge 1 ] || fail "phase 50: the true name never reached the guest in the control"
# THE HONESTY ASSERTION: the row names ONLY the author that actually ran.  With
# the claim seat compiled out (and --require-justification still armed), that is
# the JUSTIFICATION author — never `claim`.
n=$(pyq "$CC_LOG" "len([r for r in rows if r.get('call_id')=='call_CM_0002' and 'claim' in (r.get('author') or '')])")
[ "$n" -eq 0 ] || fail "phase 50: the control's log names the claim author, which did NOT run — a claim wider than the evidence"
n=$(pyq "$CC_LOG" "len([r for r in rows if r.get('call_id')=='call_CM_0002' and r.get('verdict')=='allowed' and r.get('author')=='justification'])")
[ "$n" -ge 1 ] || fail "phase 50: the control's log does not name author=justification — the SAME flags ran, only the claim seat was compiled out"
# P7-fix, the SAME honesty rule on the allow_scope: it must NOT name a claim
# seat that did not run (the P6 text, unchanged, is what the control carries).
n=$(pyq "$CC_LOG" "len([r for r in rows if r.get('call_id')=='call_CM_0002' and r.get('verdict')=='allowed' and 'claim' not in (r.get('allow_scope') or '')])")
[ "$n" -ge 1 ] || fail "phase 50: the control's allow_scope names a claim seat that did NOT run — a claim wider than the evidence"
echo "   OK pre-fix fail-open: with the claim seat compiled out the SAME pinned policy refuses nothing — the forbidden call crosses and EXECUTES, and the row names ONLY justification (never claim)"


echo "== phase 51: P7-fix THE EVALUATOR IS PINNED — a swapped always-derives evaluator is REFUSED at startup"
# The reviewer's REPRODUCED SILENT ALLOW, end to end: replace eval_calls.py —
# the file that COMPUTES every verdict — with an always-`derives` script.  The
# seat must refuse BEFORE it serves; arming with an unpinned evaluator is the
# silent allow (a stale pre-head-check evaluator is the A6b bug shipped).
cp -r "$CALLS_DIR" "$TMP/calls-swap"
cat > "$TMP/calls-swap/eval_calls.py" <<'PY'
import sys
print("verdict\tderives\tjustified(calla)\trows=1")
sys.exit(0)
PY
cmp -s "$CALLS_DIR/eval_calls.py" "$TMP/calls-swap/eval_calls.py" \
    && fail "phase 51: the evaluator swap matched NOTHING"
"$GATE" --upstream "$FIX/responses_simple.sse" --slave-file "$TMP/calls-swap-slave" \
    --log "$TMP/calls-swap-log.jsonl" --calls-policy-dir "$TMP/calls-swap" \
    --require-justification 2> "$TMP/calls-swap-err"
src=$?
[ "$src" -ne 0 ] || fail "phase 51: the swapped evaluator did NOT refuse at startup (rc=$src)"
grep -q 'eval_calls.py sha256 mismatch' "$TMP/calls-swap-err" \
    || { tail -3 "$TMP/calls-swap-err" >&2; fail "phase 51: the refusal does not name eval_calls.py's pin mismatch"; }
grep -q 'seat ARMED' "$TMP/calls-swap-err" \
    && fail "phase 51: the seat ARMED with a swapped evaluator — the pin is not yet a gate"
echo "   OK swapped evaluator REFUSED: the seat dies before serving, naming eval_calls.py's sha mismatch"
# PRE-FIX CONTROL (the SAME source, the evaluator exempt from the pin): the
# seat arms happily and the forbidden call CROSSES and EXECUTES — the reproduced
# silent allow, so the refusal above is the pin's doing and not the scenario's.
calls_guest_arm "$GATENOEVALPIN" "$TMP/calls-forbidden.sse" evalpin "$TMP/calls-swap"
[ "$CC_RC" -eq 0 ] || fail "phase 51: the pre-fix control run rc=$CC_RC"
grep -q 'seat ARMED' "$CC_ERR" || fail "phase 51: the pre-fix control did NOT arm with the swapped evaluator"
[ -f "$CC_MA" ] || fail "phase 51: the pre-fix control did NOT execute the forbidden call — the swap is not the silent allow it claims to be"
n=$(pyq "$CC_LOG" "len([r for r in rows if r.get('call_id')=='call_CM_0002' and r.get('verdict')=='allowed'])")
[ "$n" -ge 1 ] || fail "phase 51: the pre-fix control's log does not show the swapped evaluator ALLOWING the forbidden call"
echo "   OK pre-fix control: with the evaluator exempt from the pin the swapped always-derives script ARMS and lets fx_activate CROSS and EXECUTE (verdict=allowed) — the pin is what refuses it"

echo "== phase 52: P7-fix THE PER-CALL EVALUATOR IS BOUNDED — a hung one is a RECORDED refusal, not a silent stall"
# A sleeper evaluator (RE-PINNED, so the pin check passes and the bound is what
# is under test) and a tightened bound via FX_HOSTGATE_EVAL_TIMEOUT so the arm
# runs in seconds.  The forbidden call is driven straight down the chardev (the
# property — a judged call and its row — is guest-independent).
cp -r "$CALLS_DIR" "$TMP/calls-slow"
printf 'import time\ntime.sleep(600)\n' > "$TMP/calls-slow/eval_calls.py"
cmp -s "$CALLS_DIR/eval_calls.py" "$TMP/calls-slow/eval_calls.py" \
    && fail "phase 52: the sleeper write matched NOTHING"
sha=$(sha256sum "$TMP/calls-slow/eval_calls.py" | cut -d' ' -f1)
awk -F'\t' -v f="eval_calls.py" 'BEGIN{OFS="\t"} $1!=f' "$TMP/calls-slow/PINS" > "$TMP/calls-slow/PINS.new"
printf 'eval_calls.py\t%s\n' "$sha" >> "$TMP/calls-slow/PINS.new"
mv "$TMP/calls-slow/PINS.new" "$TMP/calls-slow/PINS"
FX_HOSTGATE_EVAL_TIMEOUT=2 "$GATE" --upstream "$TMP/calls-forbidden.sse" \
    --slave-file "$TMP/calls-slow-slave" --log "$TMP/calls-slow-log.jsonl" \
    --calls-policy-dir "$TMP/calls-slow" --require-justification --turns 1 \
    2> "$TMP/calls-slow-err" &
PSLOW=$!
PROXIES="$PROXIES $PSLOW"
wait_for_slave "$TMP/calls-slow-slave" "$PSLOW" "$TMP/calls-slow-err"
drive_frame "$(cat "$TMP/calls-slow-slave")"
wait_for_proxy_exit "$PSLOW" "$TMP/calls-slow-err"
wait "$PSLOW"; prc=$?
[ "$prc" -eq 0 ] || { tail -3 "$TMP/calls-slow-err" >&2; fail "phase 52: the bounded seat exited rc=$prc — it must survive a hung evaluator"; }
n=$(pyq "$TMP/calls-slow-log.jsonl" "len([r for r in rows if r.get('call_id')=='call_CM_0002' and r.get('verdict')=='denied' and r.get('author')=='claim' and r.get('refusal_name')=='denied-by-claim'])")
[ "$n" -ge 1 ] || { tail -2 "$TMP/calls-slow-log.jsonl" >&2; fail "phase 52: NO row for the stalled call — the dead-agent instrument is blind (the pre-fix shape)"; }
n=$(pyq "$TMP/calls-slow-log.jsonl" "len([r for r in rows if r.get('call_id')=='call_CM_0002' and 'did not finish within the seat' in (r.get('reason') or '') and '(2 s)' in (r.get('reason') or '')])")
[ "$n" -ge 1 ] || fail "phase 52: the refusal does not name the timeout and the EFFECTIVE bound"
echo "   OK bounded evaluator: the seat survives, the call is refused BY NAME and the row is WRITTEN — the dead-agent instrument sees the call"
# PRE-FIX CONTROL (the SAME source, NO deadline): the seat blocks on the
# evaluator forever, the turn ends with the call never judged, and NOTHING is
# written — the reviewer's whole-seat stall with a silent record.  Bounded here
# by `timeout`, because the control is a hang and the gate must always end.
rm -f "$TMP/calls-nob-slave" "$TMP/calls-nob-log.jsonl"
timeout 8 "$GATENOBOUND" --upstream "$TMP/calls-forbidden.sse" \
    --slave-file "$TMP/calls-nob-slave" --log "$TMP/calls-nob-log.jsonl" \
    --calls-policy-dir "$TMP/calls-slow" --require-justification --turns 1 \
    2> "$TMP/calls-nob-err" &
PNOB=$!
PROXIES="$PROXIES $PNOB"
wait_for_slave "$TMP/calls-nob-slave" "$PNOB" "$TMP/calls-nob-err"
drive_frame "$(cat "$TMP/calls-nob-slave")"
wait "$PNOB"; nrc=$?
[ "$nrc" -eq 124 ] || fail "phase 52: the unbounded control did NOT hang (rc=$nrc) — the sleeper did not stall the seat"
[ ! -s "$TMP/calls-nob-log.jsonl" ] || fail "phase 52: the unbounded control WROTE a log row — the instrument was not blind to the stalled call"
echo "   OK pre-fix control: with NO bound the seat HANGS (reaped by timeout, rc 124) and writes NO row — the stall the bound turns into a recorded refusal"

echo "== phase 53: P7-fix A SHARED FOLDED VERB-SYMBOL IS REFUSED BY THE SEAT'S OWN LOADER"
# --check-verbs refuses it (phase 45's verbs-dup-symbol); the C loader must too,
# or a deployment that bypasses the check would accept a table where one
# contention justifies TWO runtime verbs.  The table is RE-PINNED first, so the
# pin check passes and the refusal under test is the loader's.
cp -r "$CALLS_DIR" "$TMP/calls-dup"
awk -F'\t' 'BEGIN{OFS="\t"} {print} $1=="fx_write"{print "fx_ls","Writeverb","Inspect","no"}' \
    "$CALLS_DIR/calls-verbs.tsv" > "$TMP/calls-dup/calls-verbs.tsv"
cmp -s "$CALLS_DIR/calls-verbs.tsv" "$TMP/calls-dup/calls-verbs.tsv" \
    && fail "phase 53: the loader dup rewrite matched NOTHING"
sha=$(sha256sum "$TMP/calls-dup/calls-verbs.tsv" | cut -d' ' -f1)
awk -F'\t' -v f="calls-verbs.tsv" 'BEGIN{OFS="\t"} $1!=f' "$TMP/calls-dup/PINS" > "$TMP/calls-dup/PINS.new"
printf 'calls-verbs.tsv\t%s\n' "$sha" >> "$TMP/calls-dup/PINS.new"
mv "$TMP/calls-dup/PINS.new" "$TMP/calls-dup/PINS"
"$GATE" --upstream "$FIX/responses_simple.sse" --slave-file "$TMP/calls-dup-slave" \
    --log "$TMP/calls-dup-log.jsonl" --calls-policy-dir "$TMP/calls-dup" \
    --require-justification 2> "$TMP/calls-dup-err"
drc=$?
[ "$drc" -ne 0 ] || fail "phase 53: the seat ACCEPTED a table whose verb-symbol is mapped by two runtime verbs (rc=$drc)"
grep -q "mapped by BOTH 'fx_write' and 'fx_ls'" "$TMP/calls-dup-err" \
    || { tail -3 "$TMP/calls-dup-err" >&2; fail "phase 53: the loader refusal does not name both runtime verbs sharing the symbol"; }
grep -q 'seat ARMED' "$TMP/calls-dup-err" \
    && fail "phase 53: the seat ARMED on a duplicate-symbol table"
echo "   OK loader refuses the share form: the SAME table --check-verbs refuses is refused by the seat's own loader, naming BOTH runtime verbs"


echo "== phase 54: P7-fix THE OPERATOR-ENV FOOTGUNS — an unquotable TMPDIR refused, the armed-without-justification shape NAMED at startup"
# (a) TMPDIR rides the evaluator's command line (single-quoted), so a quote or
# control character cannot be shell-quoted safely — refused BEFORE serving.
TMPDIR="/tmp/fx-bad'quote" "$GATE" --upstream "$FIX/responses_simple.sse" \
    --slave-file "$TMP/calls-badtmp-slave" --log "$TMP/calls-badtmp-log.jsonl" \
    --calls-policy-dir "$CALLS_DIR" --require-justification 2> "$TMP/calls-badtmp-err"
trc=$?
[ "$trc" -ne 0 ] || fail "phase 54: a TMPDIR carrying a quote was ACCEPTED (rc=$trc)"
grep -q 'TMPDIR' "$TMP/calls-badtmp-err" \
    || { tail -3 "$TMP/calls-badtmp-err" >&2; fail "phase 54: the refusal does not name TMPDIR"; }
grep -q 'seat ARMED' "$TMP/calls-badtmp-err" && fail "phase 54: the seat ARMED with an unquotable TMPDIR"
# the control: the SAME dir and flags with a sane TMPDIR ARM (the refusal is
# TMPDIR's, not the fixture's) and carry NO footgun note (--require-justification
# is given).
mkdir -p "$TMP/fx-oktmp"
TMPDIR="$TMP/fx-oktmp" timeout 3 "$GATE" --upstream "$FIX/responses_simple.sse" \
    --slave-file "$TMP/calls-oktmp-slave" --log "$TMP/calls-oktmp-log.jsonl" \
    --calls-policy-dir "$CALLS_DIR" --require-justification 2> "$TMP/calls-oktmp-err"
grep -q 'seat ARMED' "$TMP/calls-oktmp-err" \
    || { tail -3 "$TMP/calls-oktmp-err" >&2; fail "phase 54: a sane TMPDIR did not arm — the refusal is not TMPDIR's"; }
grep -q 'WITHOUT --require-justification' "$TMP/calls-oktmp-err" \
    && fail "phase 54: the footgun note fires even WITH --require-justification"
echo "   OK TMPDIR: a quote-carrying TMPDIR is refused before serving; a sane one arms, and the arm IS reached (the refusal is TMPDIR's)"
# (b) the armed-without-justification footgun is NAMED at startup (the
# instrument already surfaces it as denial_rate 1.0000; this is the one-line
# diagnosis at start).  The mechanism is NOT rebuilt — only the sentence added.
timeout 3 "$GATE" --upstream "$FIX/responses_simple.sse" \
    --slave-file "$TMP/calls-noreq-slave" --log "$TMP/calls-noreq-log.jsonl" \
    --calls-policy-dir "$CALLS_DIR" 2> "$TMP/calls-noreq-err"
grep -q 'seat ARMED' "$TMP/calls-noreq-err" || fail "phase 54: the claim author did not arm without --require-justification"
grep -q 'WITHOUT --require-justification' "$TMP/calls-noreq-err" \
    || { tail -3 "$TMP/calls-noreq-err" >&2; fail "phase 54: arming the claim author without --require-justification is not NAMED at startup"; }
grep -q 'denial_rate 1.0000' "$TMP/calls-noreq-err" \
    || fail "phase 54: the footgun note does not name the record shape it produces (denial_rate 1.0000)"
echo "   OK startup sentence: arming the claim author without --require-justification names the consequence (every call denied, denial_rate 1.0000) in ONE line — and not when the flag is given"


# ── P8: RESUME, AND THE ONE LOG AS THE JOIN STATE ─────────────────────────
#
# DIRECTION (stated up front): THE LOG IS ALSO THE JOIN STATE, so the failure
# this slice must never have is a SILENTLY EMPTY MAP after a restart — the
# process starts, serves, every line looks protective, and every pre-restart
# denial has quietly lost its restore/substitution.  The MEASURED defect it
# starts from is worse than that framing: the log used to be rendered from an
# in-memory state array that started EMPTY on every process start and was
# never read back, so a second run against the same --log REPLACED the first
# run's RECORD (the writer's own rule — "a record that silently stops is the
# one failure mode this seat must never have" — broken by the writer).  So the
# arms below assert BOTH halves BY CONTENT: the earlier rows are still there,
# and the earlier denial is restored + substituted on the outbound leg.
#
# THE ASYMMETRY: build/fx-hostgate-nologload is the SAME source with the load
# compiled out (-DFH_MUTANT_NO_LOG_LOAD) — the pre-fix shape.  The SAME
# scenario (one helper, two binaries) must show the prior rows GONE and the
# old denied items crossing un-restored and un-substituted.  A gate that
# cannot catch that build is not a gate.
P8CALL_A="call_P8_A"  # get_weather — DENIED under --deny get_weather
P8CALL_B="call_P8_B"  # fx_write    — allowed: run 2's own call, a distinct key

# p8_frame <dest> [<kind> <name> <call-id> <payload>]... — a request frame in
# the chardev contract: the user message first, then one item per 4-tuple.
#   fc  : a function_call item (payload = its raw arguments JSON)
#   out : a function_call_output item (payload = the output text; name = '-')
# Hand-building the resumed conversation here is the point: the guest replays
# exactly these items (agent_loop.c:91-104 serializes function_call /
# function_call_output), so this is what the proxy would see after a resume —
# and with real JSON encoding instead of hand-escaped literals.
p8_frame() {
    python3 - "$@" <<'PY'
import json, sys
dest = sys.argv[1]
items = [{"type": "message", "role": "user", "content": "hi"}]
rest = sys.argv[2:]
for i in range(0, len(rest), 4):
    kind, name, cid, payload = rest[i:i + 4]
    if kind == "fc":
        items.append({"type": "function_call", "name": name, "call_id": cid,
                      "arguments": payload})
    elif kind == "out":
        items.append({"type": "function_call_output", "call_id": cid,
                      "output": payload})
    else:
        raise SystemExit("p8_frame: unknown item kind " + kind)
open(dest, "w").write(json.dumps({"model": "m", "stream": True, "input": items}))
PY
}

# p8_drive <slave-path> <frame-file> — one request frame straight down the
# chardev, drained to response.completed, then close (the proxy's turn-end
# cue).  drive_frame's mechanics with the frame read from a file.
p8_drive() {
    python3 - "$1" "$2" <<'PY'
import os, select, sys, time
frame = open(sys.argv[2], "rb").read()
fd = os.open(sys.argv[1], os.O_RDWR | os.O_APPEND)
os.write(fd, b"%d\n" % len(frame) + frame)
deadline = time.time() + 15
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

# p8_n <log> <predicate-over-r> — the number of rows matching (0, loudly
# silent, when the file is unreadable — the asserts below add their own
# messages).
p8_n() {
    local n
    n=$(pyq "$1" "len([r for r in rows if $2])" 2>/dev/null) || n=0
    [ -n "$n" ] || n=0
    echo "$n"
}

# p8_restart_arm <gate> <tag> — THE P8 SCENARIO, ONCE, so both binaries run
# the SAME arm and only the compile-time difference can explain a difference:
#   run 1  — the proxy serves ONE turn (the canned upstream's denied call) and
#            is SIGKILLed MID-MULTI-TURN (it is waiting for turn 2).  The
#            row is written by the DECODE, which runs before the served bytes
#            reach the driver, so the bounded wait below is not a race.
#   run 2  — a fresh process against the SAME --log, whose FIRST request frame
#            is the RESUMED conversation: the old call (as the guest
#            serialized it — the reserved name) plus the guest's sentinel
#            output for it.
# Every proxy started here is kill -9'd or reaped by wait_for_proxy_exit
# (bounded, loud) — none is left running.
p8_restart_arm() {
    local gate="$1" tag="$2" d="$P8/$2" i p1 p2
    mkdir -p "$d"
    "$gate" --upstream "$P8/upA.sse" --slave-file "$d/slave1" \
        --log "$d/log.jsonl" --deny get_weather --turns 2 2> "$d/err1" &
    p1=$!
    PROXIES="$PROXIES $p1"
    wait_for_slave "$d/slave1" "$p1" "$d/err1"
    p8_drive "$(cat "$d/slave1")" "$P8/f1.json"
    i=0
    while [ "$(p8_n "$d/log.jsonl" "r.get('call_id')=='$P8CALL_A'")" -lt 1 ] \
          && [ "$i" -lt 100 ]; do
        sleep 0.05
        i=$((i + 1))
    done
    [ "$(p8_n "$d/log.jsonl" "r.get('call_id')=='$P8CALL_A'")" -ge 1 ] \
        || fail "p8_restart_arm($tag): run 1 never recorded the denied call — the arm is not the scenario"
    kill -9 "$p1" 2>/dev/null
    wait "$p1" 2>/dev/null
    P8_TSTATS=$(grep -m1 '"type":"turn-stats"' "$d/log.jsonl")
    [ -n "$P8_TSTATS" ] \
        || fail "p8_restart_arm($tag): run 1 wrote no turn-stats row — the byte-preservation assert below would be vacuous"
    cp "$d/log.jsonl" "$d/log.run1.jsonl"
    "$gate" --upstream "$P8/upB.sse" --slave-file "$d/slave2" \
        --log "$d/log.jsonl" --deny get_weather --turns 1 \
        --dump-requests "$d/dump2.jsonl" 2> "$d/err2" &
    p2=$!
    PROXIES="$PROXIES $p2"
    wait_for_slave "$d/slave2" "$p2" "$d/err2"
    p8_drive "$(cat "$d/slave2")" "$P8/f2.json"
    wait_for_proxy_exit "$p2" "$d/err2"
    wait "$p2"
    P8_RC2=$?
    P8_LOG="$d/log.jsonl"
    P8_DUMP="$d/dump2.jsonl"
    P8_ERR1="$d/err1"
    P8_ERR2="$d/err2"
    P8_RUN1="$d/log.run1.jsonl"
}

echo "== phase 55: P8 THE LOG SURVIVES A RESTART — one --log, two runs, and the deny map REBUILT from it"
# THE DEFECT, FIRST: run 1 is KILLED mid-multi-turn, run 2 starts against the
# same --log.  Both halves are asserted BY CONTENT (never by exit status: both
# runs exit 0 either way, and a wiped record exits 0 perfectly happily).
P8="$TMP/p8"
mkdir -p "$P8"
ops_stream "$P8/upA.sse" get_weather /fx/disk/shared "$P8CALL_A"
ops_stream "$P8/upB.sse" fx_write /fx/disk/agent-data "$P8CALL_B"
p8_frame "$P8/f1.json"
p8_frame "$P8/f2.json" \
    fc fx_host_denied "$P8CALL_A" '{"path": "/fx/disk/shared"}' \
    out - "$P8CALL_A" '(tool call failed)'
# the two frames must be DIFFERENT, or "the resumed conversation" is a fiction
cmp -s "$P8/f1.json" "$P8/f2.json" \
    && fail "phase 55: the two request frames are identical — the resumed-conversation arm carries nothing"
p8_restart_arm "$GATE" arm
[ "$P8_RC2" -eq 0 ] || { tail -5 "$P8_ERR2" >&2; fail "phase 55: run 2 rc=$P8_RC2"; }
# (1) THE LOAD IS ANNOUNCED — a proxy that silently did not load is visible
grep -q "log: LOADED" "$P8_ERR2" \
    || { tail -3 "$P8_ERR2" >&2; fail "phase 55: run 2 does not report loading the existing log"; }
grep -q "REBUILT with 1 key" "$P8_ERR2" \
    || fail "phase 55: run 2 does not report rebuilding the deny map from the log"
grep -q "carried" "$P8_ERR2" \
    || fail "phase 55: the startup line does not say how much record it carried in"
echo "   OK loaded: $(grep -m1 'log: LOADED' "$P8_ERR2" | sed 's/^[^:]*: //')"
# (2) THE PRIOR ROWS SURVIVE — the measured defect, now fixed
n=$(p8_n "$P8_LOG" "r.get('call_id')=='$P8CALL_A' and r.get('verdict')=='denied' and r.get('true_name')=='get_weather'")
[ "$n" -ge 1 ] || { sed -n '1,3p' "$P8_LOG" >&2; fail "phase 55: run 1's DENIED row is GONE after the restart — the log did not survive (the measured defect)"; }
grep -qF "$P8_TSTATS" "$P8_LOG" \
    || fail "phase 55: run 1's own turn-stats row is not in the log byte-for-byte — carried rows must not be reworded"
echo "   OK survives: run 1's denied row for $P8CALL_A (true_name get_weather) is still in the log, and its telemetry row is there BYTE-FOR-BYTE"
# (3) THE CARRIED ROW'S JOIN CLOSES ON THE RESUMED REQUEST — the re-render
# path reflects state changes (a byte-copied row could not)
n=$(p8_n "$P8_LOG" "r.get('call_id')=='$P8CALL_A' and r.get('verdict')=='denied' and r.get('pending') is False and r.get('outcome')=='(tool call failed)'")
[ "$n" -ge 1 ] || fail "phase 55: the resumed request's function_call_output did not JOIN the carried row (pending/outcome unchanged)"
# (4) THE JOIN STATE WAS NOT LOST — no unjoined-output anomaly for the old call
n=$(p8_n "$P8_LOG" "r.get('type')=='unjoined-output' and r.get('call_id')=='$P8CALL_A'")
[ "$n" -eq 0 ] || { grep unjoined "$P8_ERR2" >&2; fail "phase 55: the old call's output matched NO decoded call — the rebuilt map did not recognise it"; }
# (5) THE REBUILT MAP DRIVES THE OUTBOUND LEG — restore + substitute
n=$(pyq "$P8_DUMP" "len([i for r in rows for i in r.get('input',[]) if i.get('type')=='function_call' and i.get('call_id')=='$P8CALL_A' and i.get('name')=='get_weather'])")
[ "$n" -ge 1 ] || { cat "$P8_DUMP" >&2; fail "phase 55: the model-facing frame does NOT restore the true name of a pre-restart denial"; }
n=$(pyq "$P8_DUMP" "len([i for r in rows for i in r.get('input',[]) if i.get('type')=='function_call_output' and i.get('call_id')=='$P8CALL_A' and isinstance(i.get('output'),str) and i['output'].startswith('(denied by host policy:')])")
[ "$n" -ge 1 ] || { cat "$P8_DUMP" >&2; fail "phase 55: the pre-restart denial's output was NOT substituted on the outbound leg"; }
n=$(pyq "$P8_DUMP" "len([i for r in rows for i in r.get('input',[]) if i.get('name')=='fx_host_denied' or i.get('output')=='(tool call failed)'])")
[ "$n" -eq 0 ] || { cat "$P8_DUMP" >&2; fail "phase 55: the reserved name / raw sentinel reached the MODEL — the rebuilt map did not fire"; }
echo "   OK restored+substituted: the model-facing frame carries get_weather (the true name) and '(denied by host policy: …)' as the call's own result — the reserved name and the sentinel appear NOWHERE in it"
# (6) BOTH RUNS ARE IN THE RECORD
n=$(p8_n "$P8_LOG" "r.get('call_id')=='$P8CALL_B' and r.get('verdict')=='allowed'")
[ "$n" -ge 1 ] || fail "phase 55: run 2's own call was not recorded — the file is not the CONTINUATION of the record"
echo "   OK continuation: the same file now holds run 1's denied $P8CALL_A AND run 2's allowed $P8CALL_B"

echo "== phase 56: P8 PRE-FIX CONTROL — the SAME scenario with the LOAD COMPILED OUT wipes the log (the gate MUST catch it)"
p8_restart_arm "$GATENOLOGLOAD" ctl
[ "$P8_RC2" -eq 0 ] || { tail -5 "$P8_ERR2" >&2; fail "phase 56: the control run rc=$P8_RC2"; }
grep -q "LOAD COMPILED OUT (FH_MUTANT_NO_LOG_LOAD)" "$P8_ERR2" \
    || { tail -3 "$P8_ERR2" >&2; fail "phase 56: the control does not say the load is compiled out"; }
# THE ASYMMETRY, half 1: the prior record is GONE (the wipe the brief measured).
# The count is over CALL rows (`type` absent — a telemetry row also carries the
# call_id, and the control DOES emit one for this call, below).
n=$(p8_n "$P8_LOG" "r.get('call_id')=='$P8CALL_A' and r.get('type') is None")
[ "$n" -eq 0 ] || { sed -n '1,3p' "$P8_LOG" >&2; fail "phase 56: the pre-fix control did NOT wipe run 1's row — the control does not reproduce the defect, so phase 55's survival assert proves nothing"; }
grep -qF "$P8_TSTATS" "$P8_LOG" \
    && fail "phase 56: the control reproduced run 1's telemetry row — it did not wipe the record"
echo "   OK wipe: with the load compiled out, run 2 REPLACED run 1's record — $P8CALL_A is gone and its telemetry row with it"
# THE ASYMMETRY, half 2: the old denied items cross un-restored / un-substituted
n=$(pyq "$P8_DUMP" "len([i for r in rows for i in r.get('input',[]) if i.get('type')=='function_call' and i.get('call_id')=='$P8CALL_A' and i.get('name')=='fx_host_denied'])")
[ "$n" -ge 1 ] || { cat "$P8_DUMP" >&2; fail "phase 56: the control restored the true name without loading anything — the mechanism is not the load"; }
n=$(pyq "$P8_DUMP" "len([i for r in rows for i in r.get('input',[]) if i.get('type')=='function_call_output' and i.get('call_id')=='$P8CALL_A' and i.get('output')=='(tool call failed)'])")
[ "$n" -ge 1 ] || { cat "$P8_DUMP" >&2; fail "phase 56: the control substituted the denial text with an EMPTY map"; }
n=$(p8_n "$P8_LOG" "r.get('type')=='unjoined-output' and r.get('call_id')=='$P8CALL_A'")
[ "$n" -ge 1 ] || fail "phase 56: the control shows no unjoined-output anomaly — the LOST join state left no trace in its record"
echo "   OK un-restored: the model would see fx_host_denied + '(tool call failed)' for a call IT made before the restart, and the control's own log carries the unjoined-output anomaly — the empty map is what makes phase 55's asserts load-bearing"
# and the control's own silent-empty-map instrument: the digest of a GOOD log
n=$("$GATENOLOGLOAD" --print-log-state "$P8_RUN1" 2>/dev/null | head -1)
case "$n" in
    "log-state rows=0 "*) : ;;
    *) fail "phase 56: the control's --print-log-state did not report an EMPTY state (got '$n')";;
esac
echo "   OK silent empty map: the control's own state digest of a populated log reads '$n'"

echo "== phase 57: P8 IDEMPOTENT REPLAY — the loader is a pure function of the file, and load->flush neither duplicates nor rewords"
# The property, stated so it can FAIL: (a) loading the same bytes twice yields
# the identical state; (b) a run that loads the log and mutates NOTHING
# reproduces the carried lines BYTE-FOR-BYTE (no duplication, no rewording);
# (c) that run does not change the counts the state digest reports.
"$GATE" --print-log-state "$P8/arm/log.jsonl" > "$P8/st1.txt" 2> "$P8/st1.err"
r1=$?
"$GATE" --print-log-state "$P8/arm/log.jsonl" > "$P8/st2.txt" 2>/dev/null
r2=$?
[ "$r1" -eq 0 ] && [ "$r2" -eq 0 ] || fail "phase 57: --print-log-state rc=$r1/$r2"
cmp -s "$P8/st1.txt" "$P8/st2.txt" \
    || { diff "$P8/st1.txt" "$P8/st2.txt" >&2; fail "phase 57: loading the SAME file twice yielded DIFFERENT state — the replay is not idempotent"; }
grep -q '^dmap ' "$P8/st1.txt" \
    || { cat "$P8/st1.txt" >&2; fail "phase 57: the digest carries no deny-map entries — it cannot see the join state it is meant to describe"; }
echo "   OK pure: the digest of the same log is byte-identical across two loads — $(head -1 "$P8/st1.txt")"
# (b) NO-MUTATION ROUND TRIP: a run that loads the log, decodes a NO-CALL
# upstream (responses_simple.sse) and joins nothing.  The only new line is the
# exit row, so the carried bytes must come back exactly.
cp "$P8/arm/log.jsonl" "$P8/roundtrip.jsonl"
before=$(wc -c < "$P8/roundtrip.jsonl")
"$GATE" --upstream "$FIX/responses_simple.sse" --slave-file "$P8/slave3" \
    --log "$P8/roundtrip.jsonl" --turns 1 2> "$P8/err3" &
P8C=$!
PROXIES="$PROXIES $P8C"
wait_for_slave "$P8/slave3" "$P8C" "$P8/err3"
p8_drive "$(cat "$P8/slave3")" "$P8/f1.json"
wait_for_proxy_exit "$P8C" "$P8/err3"
wait "$P8C" || fail "phase 57: the no-call round-trip run exited nonzero"
[ "$(wc -c < "$P8/roundtrip.jsonl")" -gt "$before" ] \
    || fail "phase 57: the round-trip run wrote nothing — the flush never happened, so the round trip is untested"
head -c "$before" "$P8/roundtrip.jsonl" > "$P8/roundtrip.pfx"
cmp -s "$P8/roundtrip.pfx" "$P8/arm/log.jsonl" \
    || { diff <(head -c "$before" "$P8/roundtrip.jsonl") "$P8/arm/log.jsonl" >&2; fail "phase 57: load->flush did not reproduce the carried rows byte-for-byte (duplication or rewording)"; }
echo "   OK round trip: a load-and-flush with nothing mutated reproduces all $before carried byte(s) EXACTLY, then appends this run's exit row"
# (c) the state digest's counts are unchanged by that run
"$GATE" --print-log-state "$P8/roundtrip.jsonl" > "$P8/st3.txt" 2>/dev/null
d1=$(grep -o 'calls=[0-9]* denied=[0-9]* pending=[0-9]*' "$P8/st1.txt")
d3=$(grep -o 'calls=[0-9]* denied=[0-9]* pending=[0-9]*' "$P8/st3.txt")
[ "$d1" = "$d3" ] || { cat "$P8/st1.txt" "$P8/st3.txt" >&2; fail "phase 57: the round trip changed the call/deny/pending counts ($d1 -> $d3) — a carried row was re-applied"; }
diff <(grep '^dmap ' "$P8/st1.txt") <(grep '^dmap ' "$P8/st3.txt") >/dev/null \
    || { diff <(grep '^dmap ' "$P8/st1.txt") <(grep '^dmap ' "$P8/st3.txt") >&2; fail "phase 57: the round trip changed the deny map — replay double-applied"; }
echo "   OK counts: '$d1' and the deny map are IDENTICAL before and after the round trip (no row was re-applied)"

echo "== phase 58: P8 A CORRUPT LOG REFUSES LOUDLY AND IS LEFT UNTOUCHED (silence is the failure)"
# Four corruptions, each measured on the REAL build (refusal + the file
# UNCHANGED — a refusal that also clobbered the file would be silent data
# loss) and then on the pre-fix control, where they are not noticed at all and
# the file is REPLACED.  Exits alone are not the assertion: the loudness is.
p8_corrupt() { # <tag> <file-that-must-stay-untouched> <stderr-substring>
    local tag="$1" file="$2" want="$3"
    cp "$file" "$P8/$tag.before"
    timeout 20 "$GATE" --upstream "$FIX/responses_simple.sse" \
        --slave-file "$P8/$tag.slave" --log "$file" --turns 1 \
        2> "$P8/$tag.err"
    local rc=$?
    [ "$rc" -ne 0 ] || { tail -3 "$P8/$tag.err" >&2; fail "phase 58: a $tag log was ACCEPTED (rc=$rc) — the seat served with an unloadable record"; }
    grep -q "THE ONE LOG IS NOT LOADABLE" "$P8/$tag.err" \
        || { tail -3 "$P8/$tag.err" >&2; fail "phase 58: the $tag refusal does not name the cause (the log is not loadable)"; }
    grep -q "$want" "$P8/$tag.err" \
        || { tail -3 "$P8/$tag.err" >&2; fail "phase 58: the $tag refusal does not say WHAT was wrong (want '$want')"; }
    grep -q "REFUSES TO START" "$P8/$tag.err" \
        || fail "phase 58: the $tag refusal does not say the empty map would silently un-restore the pre-restart denials"
    cmp -s "$file" "$P8/$tag.before" \
        || fail "phase 58: the $tag refusal ALSO modified the log — a refusal that clobbers the record is silent data loss"
    [ -e "$P8/$tag.slave" ] && fail "phase 58: the $tag refusal still published a slave path — it did not stop before serving"
    echo "   OK $tag: refused rc=$rc, named the cause and the gap, and left the file byte-identical"
}
printf 'not json at all\n' > "$P8/nonjson.log"
p8_corrupt nonjson "$P8/nonjson.log" "is not JSON"
head -c -1 "$P8/arm/log.jsonl" > "$P8/torn.log"   # drop the final newline
[ "$(tail -c1 "$P8/torn.log" | wc -l)" -eq 0 ] || fail "phase 58: the torn fixture still ends in a newline"
p8_corrupt torn "$P8/torn.log" "TORN row"
printf '{"hello":1}\n' > "$P8/notarow.log"
p8_corrupt notarow "$P8/notarow.log" "call_id"
head -1 "$P8/arm/log.jsonl" > "$P8/blank.log"
printf '\n' >> "$P8/blank.log"
cat "$P8/arm/log.jsonl" | head -2 >> "$P8/blank.log"
p8_corrupt removed "$P8/blank.log" "EMPTY"
# THE CONTROL: the same corruption on the pre-fix build is NOT NOTICED — the
# seat starts (rc 0 on a served turn) and its first flush REPLACES the file,
# so the corrupt evidence is gone.  That is the silent empty map, and it is
# why the four arms above are load-bearing rather than decoration.
printf 'not json at all\n' > "$P8/ctl-nonjson.log"
"$GATENOLOGLOAD" --upstream "$FIX/responses_simple.sse" --slave-file "$P8/ctl-slave" \
    --log "$P8/ctl-nonjson.log" --turns 1 2> "$P8/ctl-nonjson.err" &
P8D=$!
PROXIES="$PROXIES $P8D"
wait_for_slave "$P8/ctl-slave" "$P8D" "$P8/ctl-nonjson.err"
p8_drive "$(cat "$P8/ctl-slave")" "$P8/f1.json"
wait_for_proxy_exit "$P8D" "$P8/ctl-nonjson.err"
grep -q "THE ONE LOG IS NOT LOADABLE" "$P8/ctl-nonjson.err" \
    && fail "phase 58: the control refused a corrupt log — it does not reproduce the silent path"
# NOTE: `grep -c … | grep -qx 0` is a TRAP under this file's `set -o pipefail`
# — grep -c exits 1 when the count is 0, so the pipeline is nonzero exactly
# when the assertion HOLDS.  Captured instead (measured: that pipeline failed
# this phase on a control that had behaved correctly).
n=$(grep -c "not json at all" "$P8/ctl-nonjson.log" || true)
[ "$n" = "0" ] \
    || fail "phase 58: the control left the corrupt bytes in place ($n line(s)) — it did not REPLACE the file (the wipe)"
echo "   OK control: the same corrupt log makes the pre-fix build START and then REPLACE it silently — no refusal, no gap named, the evidence gone"

echo "== phase 59: P8 THE REBUILT MAP DRIVES A REAL RESUMED GUEST RUN (--resume through the restarted proxy)"
# The frame-driven arms above hand-build the resumed conversation; this arm
# makes the GUEST produce it: run 1 leaves a denied call in the guest's
# transcript (the reserved name + the guest's sentinel), then the SAME session
# is RESUMED through a FRESH proxy against the SAME --log, and the host's
# outbound leg must hand the model the true name and the real reason — while
# the guest's own transcript stays exactly what crossed the gate (the stated
# record-fidelity residual, restated rather than changed).
mkdir -p "$P8/data1" "$P8/cfg"
make_calls_stub "$P8/calls-stub.py" "$P8/marker-write" "$P8/marker-activate"
cat > "$P8/cfg/config.dhall" <<DHALL
{ agents =
  [ { name = "fx"
    , agent_type = "agent"
    , mcp_servers = [ { command = "$P8/calls-stub.py", args = [] : List Text } ]
    }
  ]
}
DHALL
cp "$FIX/responses_tool.sse" "$P8/gup.sse"
"$GATE" --upstream "$P8/gup.sse" --slave-file "$P8/gslave1" \
    --log "$P8/glog.jsonl" --deny get_weather --turns 2 2> "$P8/gerr1" &
P8E=$!
PROXIES="$PROXIES $P8E"
wait_for_slave "$P8/gslave1" "$P8E" "$P8/gerr1"
FX_CHARDEV="$(cat "$P8/gslave1")" FX_AGENT_CONFIG_DIR="$P8/cfg" \
FX_AGENT_DATA="$P8/data1" HOME="$TMP" \
    "$BIN" -p "$SENTINEL" --agent fx --max-turns 2 --output text \
    > "$P8/gout1" 2> "$P8/gstderr1"
g1rc=$?
[ "$g1rc" -eq 0 ] || { sed -n '1,5p' "$P8/gstderr1" >&2; fail "phase 59: run 1 rc=$g1rc"; }
wait_for_proxy_exit "$P8E" "$P8/gerr1"
wait "$P8E" || fail "phase 59: proxy A exited nonzero"
P8GTR=$(ls "$P8"/data1/sessions/*/messages.jsonl 2>/dev/null)
[ -f "$P8GTR" ] || fail "phase 59: run 1 left no transcript — the arm is not the real scenario"
n=$(pyq "$P8GTR" "len([1 for r in rows for tc in (r.get('tool_calls') or []) if tc.get('name')=='fx_host_denied' and tc.get('id')=='$CALLID'])")
[ "$n" -eq 1 ] || { cat "$P8GTR" >&2; fail "phase 59: the denied call is not in the guest's transcript under the reserved name"; }
n=$(pyq "$P8GTR" "len([1 for r in rows if r.get('role')=='tool' and r.get('tool_call_id')=='$CALLID' and r.get('content')=='(tool call failed)'])")
[ "$n" -eq 1 ] || { cat "$P8GTR" >&2; fail "phase 59: run 1 recorded no sentinel tool result — nothing for the outbound leg to substitute"; }
P8SID=$(ls "$P8/data1/sessions" | grep -v '^\.' | head -1)
[ -n "$P8SID" ] || fail "phase 59: no session id under $P8/data1/sessions"
n=$(p8_n "$P8/glog.jsonl" "r.get('call_id')=='$CALLID' and r.get('verdict')=='denied'")
[ "$n" -ge 1 ] || fail "phase 59: run 1's denial was not recorded"
echo "   OK run 1: the guest called get_weather, the gate denied it, the transcript holds fx_host_denied + the sentinel, and the log holds the denial (sid=$P8SID)"
"$GATE" --upstream "$P8/gup.sse" --slave-file "$P8/gslave2" \
    --log "$P8/glog.jsonl" --deny get_weather --turns 1 \
    --dump-requests "$P8/gdump2.jsonl" 2> "$P8/gerr2" &
P8F=$!
PROXIES="$PROXIES $P8F"
wait_for_slave "$P8/gslave2" "$P8F" "$P8/gerr2"
FX_CHARDEV="$(cat "$P8/gslave2")" FX_AGENT_CONFIG_DIR="$P8/cfg" \
FX_AGENT_DATA="$P8/data1" HOME="$TMP" \
    "$BIN" -p "$SENTINEL" --agent fx --max-turns 1 --output text --resume "$P8SID" \
    > "$P8/gout2" 2> "$P8/gstderr2"
g2rc=$?
[ "$g2rc" -eq 0 ] || { sed -n '1,5p' "$P8/gstderr2" >&2; fail "phase 59: the resumed run rc=$g2rc"; }
wait_for_proxy_exit "$P8F" "$P8/gerr2"
wait "$P8F" || fail "phase 59: proxy B exited nonzero"
grep -q "log: LOADED" "$P8/gerr2" \
    || { tail -3 "$P8/gerr2" >&2; fail "phase 59: the restarted proxy did not load the log"; }
grep -q "RESTORED call_id=$CALLID" "$P8/gerr2" \
    || { tail -20 "$P8/gerr2" >&2; fail "phase 59: the resumed request did not trigger a name RESTORE"; }
grep -q "SUBSTITUTED call_id=$CALLID" "$P8/gerr2" \
    || fail "phase 59: the resumed request did not trigger an output SUBSTITUTION"
n=$(pyq "$P8/gdump2.jsonl" "len([i for r in rows for i in r.get('input',[]) if i.get('type')=='function_call' and i.get('call_id')=='$CALLID' and i.get('name')=='get_weather'])")
[ "$n" -ge 1 ] || { cat "$P8/gdump2.jsonl" >&2; fail "phase 59: the model-facing frame does not restore the true name of the resumed call"; }
n=$(pyq "$P8/gdump2.jsonl" "len([i for r in rows for i in r.get('input',[]) if i.get('type')=='function_call_output' and i.get('call_id')=='$CALLID' and isinstance(i.get('output'),str) and i['output'].startswith('(denied by host policy:')])")
[ "$n" -ge 1 ] || { cat "$P8/gdump2.jsonl" >&2; fail "phase 59: the reason did not reach the model as the call's own result after the resume"; }
# the guest's view is UNCHANGED (what crossed the gate), and run 1's row is
# still in the record: the fidelity residual restated, and the defect fixed
n=$(pyq "$P8GTR" "len([1 for r in rows for tc in (r.get('tool_calls') or []) if tc.get('name')=='fx_activate' or tc.get('name')=='get_weather'])")
[ "$n" -eq 0 ] || fail "phase 59: the TRUE name reached the guest's transcript — zilch guest change means the transcript shows the reserved name"
n=$(p8_n "$P8/glog.jsonl" "r.get('call_id')=='$CALLID' and r.get('verdict')=='denied' and r.get('true_name')=='get_weather'")
[ "$n" -ge 1 ] || fail "phase 59: run 1's row is gone after the resumed run"
[ ! -e "$P8/marker-write" ] && [ ! -e "$P8/marker-activate" ] \
    || fail "phase 59: a stub marker fired — the denied call executed"
echo "   OK resumed guest: the restarted proxy loaded the record, restored + substituted the pre-restart denial on the frame the model sees, kept the transcript as what crossed the gate (fx_host_denied + sentinel), and nothing executed"

# ── P8-fix: THE FIVE SHOULD-FIXES FROM THE P8 REVIEW ────────────────────────
#
# DIRECTION: the review's verdict was that the load path is SOUND FOR
# ENFORCEMENT but that STRICTNESS STOPS AT STRUCTURE — CONTENT IS TRUSTED.
# Every arm below is a MEASURED defect with a PRE-FIX CONTROL built from the
# SAME source (build/fx-hostgate-loadunbound | -nodedup | -noscopecarry), so
# each new assertion is proved able to FAIL on exactly its own fixture.  The
# two ends of the log are both here: what a loaded row may make the seat DO
# (R1's unbounded restore, R5's reword), and what the seat itself WRITES (R2's
# duplicate rows and the phantom exit entry they produce).  Nothing here
# changes the guest: the crafted rows are host-side files and the frames are
# built by the harness (p8_frame), never by a run.

echo "== phase 60: P8-fix R1 — THE LOAD APPLIES THE WRITER'S OWN BOUND (a crafted-but-valid DENIED row is NOT trusted verbatim)"
# THE DEFECT (the review's probe 1, the input with teeth): FH_BOUND was applied
# only at WRITE time, so a DENIED row arriving from the FILE reached the deny
# map at full length and the outbound leg restored its true_name and emitted
# its denial_text whole.  MEASURED by the reviewer: 1,048,576 bytes, against a
# run with NO POLICY ARMED.  The row below is STRUCTURALLY VALID (every field
# the writer renders, correct types) — the fix is a BOUND, not a refusal, so
# this arm asserts the bound AND that the row still loads.
mkdir -p "$P8/fix"
python3 - "$P8/fix/crafted.jsonl" <<'PY'
import json, sys
long = "E" * (1024 * 1024)
row = {"ts": "2026-01-01T00:00:00Z", "session": None, "run": None, "turn": 1,
       "call_id": "call_R1", "true_name": long, "args": "{}",
       "pending": True, "outcome": None, "verdict": "denied", "author": "ops",
       "refusal_name": "denied-by-ops", "reason": long, "denial_text": long}
open(sys.argv[1], "w").write(json.dumps(row) + "\n")
PY
p8_frame "$P8/fix/r1frame.json" \
    fc fx_host_denied call_R1 '{"path": "/etc"}' \
    out - call_R1 '(tool call failed)'
cp "$P8/fix/crafted.jsonl" "$P8/fix/r1.log"
"$GATE" --upstream "$FIX/responses_simple.sse" --slave-file "$P8/fix/r1.slave" \
    --log "$P8/fix/r1.log" --turns 1 --dump-requests "$P8/fix/r1.dump" \
    2> "$P8/fix/r1.err" &
P8G=$!
PROXIES="$PROXIES $P8G"
wait_for_slave "$P8/fix/r1.slave" "$P8G" "$P8/fix/r1.err"
p8_drive "$(cat "$P8/fix/r1.slave")" "$P8/fix/r1frame.json"
wait_for_proxy_exit "$P8G" "$P8/fix/r1.err"
wait "$P8G"
r1rc=$?
[ "$r1rc" -eq 0 ] || { tail -3 "$P8/fix/r1.err" >&2; fail "phase 60: rc=$r1rc — the crafted row is structurally VALID, so the bound must apply to it, not refuse it"; }
grep -q "log: LOADED" "$P8/fix/r1.err" \
    || fail "phase 60: the crafted row did not load — the arm is not the scenario (nothing was carried)"
# (a) the MODEL-FACING frame: the restored name and the substituted output are
#     bounded with the explicit marker, and NOT one byte over FH_BOUND
n=$(pyq "$P8/fix/r1.dump" "max([len(i.get('name') or '') for r in rows for i in r.get('input',[]) if i.get('type')=='function_call'] or [0])")
[ "$n" -le 512 ] || { head -c 200 "$P8/fix/r1.dump" >&2; fail "phase 60: the outbound leg restored a $n-byte true_name — the loader trusted the file (FH_BOUND is 512)"; }
n=$(pyq "$P8/fix/r1.dump" "max([len(i.get('output') or '') for r in rows for i in r.get('input',[]) if i.get('type')=='function_call_output' and i.get('call_id')=='call_R1'] or [0])")
[ "$n" -gt 0 ] || { cat "$P8/fix/r1.dump" >&2; fail "phase 60: the crafted denial was NOT substituted into the output — the arm proves nothing (the row's denial_text is attacker-chosen text, so it is found by call_id, never by the host's own prefix)"; }
[ "$n" -le 512 ] || { head -c 200 "$P8/fix/r1.dump" >&2; fail "phase 60: the outbound leg emitted $n bytes of the loaded denial text (the reviewer measured 1,048,576) — the load did not apply the writer's bound"; }
n=$(pyq "$P8/fix/r1.dump" "len([1 for r in rows for i in r.get('input',[]) if isinstance(i.get('name'),str) and 'TRUNCATED from 1048576 bytes' in i['name']])")
[ "$n" -ge 1 ] || { head -c 300 "$P8/fix/r1.dump" >&2; fail "phase 60: the cut is NOT marked — a silent truncation is the lie the writer's bound exists to prevent"; }
n=$(pyq "$P8/fix/r1.dump" "len([1 for r in rows for i in r.get('input',[]) if i.get('type')=='function_call_output' and i.get('call_id')=='call_R1' and 'TRUNCATED from 1048576 bytes' in (i.get('output') or '')])")
[ "$n" -ge 1 ] || fail "phase 60: the substituted OUTPUT is not marked — the bound must carry its marker on both fields the outbound leg writes"
# (b) and the RECORD says the same thing: the carried row re-renders bounded
n=$(pyq "$P8/fix/r1.log" "len([r for r in rows if r.get('call_id')=='call_R1' and 'TRUNCATED from 1048576 bytes' in (r.get('denial_text') or '') and len(r['denial_text'])<=512 and len(r['true_name'])<=512])")
[ "$n" -eq 1 ] || { head -2 "$P8/fix/r1.log" >&2; fail "phase 60: the log's own row is not bounded+marked — the bound must hold in the record too"; }
echo "   OK bounded at load: a 1 MB true_name/denial_text loaded, the outbound frame carries at most 512 bytes with the explicit marker, and the row re-renders bounded"
# (c) THE BOUNDING EXEMPTION'S OWN ARGUMENT, RE-ESTABLISHED BY HAND: call_id
#     renders verbatim because the WIRE bounds it (it arrived in a frame); a
#     LOADED row never arrived in a frame, so the load checks the same bound.
python3 - "$P8/fix/longcid.log" <<'PY'
import json, sys
row = {"ts": "2026-01-01T00:00:00Z", "session": None, "run": None, "turn": 1,
       "call_id": "c" * (16 * 1024 * 1024 + 1), "true_name": "get_weather",
       "args": "{}", "pending": False, "outcome": None, "verdict": None}
with open(sys.argv[1], "w") as fh:
    fh.write(json.dumps(row) + "\n")
PY
timeout 30 "$GATE" --print-log-state "$P8/fix/longcid.log" > /dev/null 2> "$P8/fix/longcid.err"
rc=$?
[ "$rc" -ne 0 ] || fail "phase 60: an over-frame-length call_id LOADED (rc=0) — the join key's bounding exemption has no load-side argument"
grep -q "longer than a frame" "$P8/fix/longcid.err" \
    || { tail -2 "$P8/fix/longcid.err" >&2; fail "phase 60: the over-long call_id refusal does not name the wire bound it re-establishes"; }
echo "   OK join key: a $(wc -c < "$P8/fix/longcid.log")-byte file whose call_id exceeds a frame is REFUSED (the exemption is transitive, so the load re-establishes it)"

echo "== phase 61: P8-fix R1 PRE-FIX CONTROL — the SAME fixture with the LOAD-TIME bound compiled out (the reviewer's 1,048,576 bytes)"
# build/fx-hostgate-loadunbound is THIS source with LOAD_BOUND compiled to
# xstrdup: every loaded free-text field is trusted verbatim, exactly the
# pre-fix shape.  The flip is BY CONTENT on the same crafted row: the model
# sees the full 1 MB.  (The control still exits 0 — a wrong record, not a
# crash — which is why the assertion must be on the bytes.)
cp "$P8/fix/crafted.jsonl" "$P8/fix/r1ctl.log"
"$GATELOADUNB" --upstream "$FIX/responses_simple.sse" --slave-file "$P8/fix/r1ctl.slave" \
    --log "$P8/fix/r1ctl.log" --turns 1 --dump-requests "$P8/fix/r1ctl.dump" \
    2> "$P8/fix/r1ctl.err" &
P8H=$!
PROXIES="$PROXIES $P8H"
wait_for_slave "$P8/fix/r1ctl.slave" "$P8H" "$P8/fix/r1ctl.err"
p8_drive "$(cat "$P8/fix/r1ctl.slave")" "$P8/fix/r1frame.json"
wait_for_proxy_exit "$P8H" "$P8/fix/r1ctl.err"
wait "$P8H"
[ "$?" -eq 0 ] || fail "phase 61: the control exited nonzero — the wrong record must be silent to the exit status, not a crash"
n=$(pyq "$P8/fix/r1ctl.dump" "max([len(i.get('output') or '') for r in rows for i in r.get('input',[]) if i.get('type')=='function_call_output' and i.get('call_id')=='call_R1'] or [0])")
[ "$n" -eq 1048576 ] || { head -c 200 "$P8/fix/r1ctl.dump" >&2; fail "phase 61: the control emitted $n bytes, not the reviewer's measured 1,048,576 — the mutation did not take, so phase 60's bound is not proven"; }
n=$(pyq "$P8/fix/r1ctl.dump" "max([len(i.get('name') or '') for r in rows for i in r.get('input',[]) if i.get('type')=='function_call'] or [0])")
[ "$n" -gt 512 ] || fail "phase 61: the control's restored name is only $n bytes — the load-time bound was NOT the thing phase 60 measured"
echo "   OK control caught: with the load-time bound compiled out the same row drives the outbound leg unbounded (name $n bytes, denial text 1,048,576) — phase 60 asserts a bound the pre-fix shape does not have"

echo "== phase 62: P8-fix R2 — ONE ROW PER call_id: the re-serve is a REPEAT, and the PHANTOM is gone"
# THE DEFECT (the review, probes 2+3+5): the decode appended a fresh row for
# every re-served call, so ONE guest-side tool call left THREE call rows for
# one call_id in the gate's own phase-59 log, with a phantom UNRESOLVED entry
# reported at every exit.  Semantics NOW (stated at row_call_record in
# tools/fx-hostgate.c): a call_id identifies ONE CALL; a re-serve by the
# upstream is the upstream repeating an item, so the row is written once and a
# repeat neither re-opens nor un-answers it.  This arm drives the SAME wire
# twice (two turns carrying one call_id, then a restart) with no guest.
"$GATE" --upstream "$P8/upA.sse" --slave-file "$P8/fix/r2a.slave" \
    --log "$P8/fix/r2.log" --deny get_weather --turns 2 2> "$P8/fix/r2a.err" &
P8I=$!
PROXIES="$PROXIES $P8I"
wait_for_slave "$P8/fix/r2a.slave" "$P8I" "$P8/fix/r2a.err"
p8_drive "$(cat "$P8/fix/r2a.slave")" "$P8/f1.json"
p8_drive "$(cat "$P8/fix/r2a.slave")" "$P8/f2.json"
wait_for_proxy_exit "$P8I" "$P8/fix/r2a.err"
wait "$P8I"
[ "$?" -eq 0 ] || fail "phase 62: run 1 (two turns over one call_id) exited nonzero"
n=$(p8_n "$P8/fix/r2.log" "r.get('call_id')=='$P8CALL_A' and r.get('type') is None")
[ "$n" -eq 1 ] || { sed -n '1,4p' "$P8/fix/r2.log" >&2; fail "phase 62: expected exactly 1 call row for $P8CALL_A after two turns that re-served the SAME call_id, got $n — ONE call_id is ONE CALL"; }
n=$(p8_n "$P8/fix/r2.log" "r.get('call_id')=='$P8CALL_A' and r.get('verdict')=='denied' and r.get('pending') is False")
[ "$n" -eq 1 ] || fail "phase 62: the single row is not RESOLVED — a re-serve must not un-answer a call the join already closed"
grep -q "RE-SERVED an item" "$P8/fix/r2a.err" \
    || { tail -3 "$P8/fix/r2a.err" >&2; fail "phase 62: the re-serve was deduped SILENTLY — the semantics must be visible on stderr"; }
# THE RESTART: the same call_id is served again by a fresh process against the
# SAME log.  Nothing may inflate, and nothing may be left looking unanswered.
"$GATE" --upstream "$P8/upA.sse" --slave-file "$P8/fix/r2b.slave" \
    --log "$P8/fix/r2.log" --deny get_weather --turns 1 2> "$P8/fix/r2b.err" &
P8J=$!
PROXIES="$PROXIES $P8J"
wait_for_slave "$P8/fix/r2b.slave" "$P8J" "$P8/fix/r2b.err"
p8_drive "$(cat "$P8/fix/r2b.slave")" "$P8/f2.json"
wait_for_proxy_exit "$P8J" "$P8/fix/r2b.err"
wait "$P8J"
[ "$?" -eq 0 ] || fail "phase 62: the resumed run exited nonzero"
n=$(p8_n "$P8/fix/r2.log" "r.get('call_id')=='$P8CALL_A' and r.get('type') is None")
[ "$n" -eq 1 ] || { sed -n '1,6p' "$P8/fix/r2.log" >&2; fail "phase 62: the restarted run added a row for an already-recorded call_id (now $n rows) — the inflation the review measured"; }
n=$(pyq "$P8/fix/r2.log" "len([r for r in rows if r.get('type')=='proxy-exit'])")
[ "$n" -eq 2 ] || fail "phase 62: expected 2 proxy-exit rows to judge (one per run), got $n — the phantom assert below would be vacuous"
n=$(pyq "$P8/fix/r2.log" "len([r for r in rows if r.get('type')=='proxy-exit' and any(u.get('call_id')=='$P8CALL_A' for u in r.get('unresolved',[]))])")
[ "$n" -eq 0 ] || { sed -n '1,6p' "$P8/fix/r2.log" >&2; fail "phase 62: an exit row reports $P8CALL_A UNRESOLVED — the call was answered by the resumed run's own request, so this is the PHANTOM the review measured at every exit"; }
n=$(grep -c "UNRESOLVED" "$P8/fix/r2b.err" || true)
[ "$n" = "0" ] || fail "phase 62: the resumed run's stderr reports an unresolved call ($n line(s)) for a call it just substituted"
# THE REVIEWER'S OWN ARTIFACT: the phase-59 log was the measured 3-rows-plus-
# phantom case, so the same two properties are asserted on it directly.
n=$(p8_n "$P8/glog.jsonl" "r.get('call_id')=='$CALLID'")
[ "$n" -eq 1 ] || { sed -n '1,6p' "$P8/glog.jsonl" >&2; fail "phase 62: the phase-59 log holds $n call rows for ONE guest-side tool call (the review measured THREE before this fix)"; }
n=$(pyq "$P8/glog.jsonl" "len([r for r in rows if r.get('type')=='proxy-exit'])")
[ "$n" -eq 2 ] || fail "phase 62: phase 59's log does not carry 2 proxy-exit rows ($n) — the phantom assert would be vacuous"
n=$(pyq "$P8/glog.jsonl" "len([r for r in rows if r.get('type')=='proxy-exit' and any(u.get('call_id')=='$CALLID' for u in r.get('unresolved',[]))])")
[ "$n" -eq 0 ] || { sed -n '1,6p' "$P8/glog.jsonl" >&2; fail "phase 62: phase 59's exits still report the answered call unresolved (the review measured it at BOTH exits)"; }
# and the LOADER now matches the writer: a duplicate call_id row is refused,
# loudly, leaving the file untouched
printf '%s\n%s\n' "$(head -1 "$P8/fix/r2.log")" "$(head -1 "$P8/fix/r2.log")" > "$P8/fix/dup.log"
cp "$P8/fix/dup.log" "$P8/fix/dup.before"
timeout 20 "$GATE" --upstream "$FIX/responses_simple.sse" --slave-file "$P8/fix/dup.slave" \
    --log "$P8/fix/dup.log" --turns 1 2> "$P8/fix/dup.err"
rc=$?
[ "$rc" -ne 0 ] || fail "phase 62: a log with a DUPLICATE call_id row was ACCEPTED (rc=0) — the loader does not match the writer's one-row-per-call_id invariant"
grep -q "MORE THAN ONCE" "$P8/fix/dup.err" \
    || { tail -2 "$P8/fix/dup.err" >&2; fail "phase 62: the duplicate refusal does not name the invariant"; }
grep -q "REFUSES TO START" "$P8/fix/dup.err" || fail "phase 62: the duplicate refusal is not the loud refusal"
cmp -s "$P8/fix/dup.log" "$P8/fix/dup.before" || fail "phase 62: the duplicate refusal clobbered the file"
[ -e "$P8/fix/dup.slave" ] && fail "phase 62: the duplicate refusal still published a slave path"
echo "   OK one row per call_id: two turns and a restart over ONE call_id leave exactly 1 row, no exit row reports it unresolved (.stderr neither), phase 59's own log holds 1 row for its one guest-side call, and the loader REFUSES a duplicate row"

echo "== phase 63: P8-fix R2 PRE-FIX CONTROL — one row per OBSERVATION (the inflation + the phantom return)"
# build/fx-hostgate-nodedup is THIS source with the dedup compiled out: the
# pre-fix shape.  Same upstream, same two turns, same log shape — so the
# phase-62 assertions flip BY CONTENT.
"$GATENODEDUP" --upstream "$P8/upA.sse" --slave-file "$P8/fix/r2c.slave" \
    --log "$P8/fix/r2c.log" --deny get_weather --turns 2 2> "$P8/fix/r2c.err" &
P8K=$!
PROXIES="$PROXIES $P8K"
wait_for_slave "$P8/fix/r2c.slave" "$P8K" "$P8/fix/r2c.err"
p8_drive "$(cat "$P8/fix/r2c.slave")" "$P8/f1.json"
p8_drive "$(cat "$P8/fix/r2c.slave")" "$P8/f2.json"
wait_for_proxy_exit "$P8K" "$P8/fix/r2c.err"
wait "$P8K"
[ "$?" -eq 0 ] || fail "phase 63: the control exited nonzero — the wrong record must be silent to the exit status"
n=$(p8_n "$P8/fix/r2c.log" "r.get('call_id')=='$P8CALL_A' and r.get('type') is None")
[ "$n" -ge 2 ] || { sed -n '1,4p' "$P8/fix/r2c.log" >&2; fail "phase 63: the control recorded $n row(s) for a call_id it served twice — the mutation did not take, so phase 62's single-row assert proves nothing"; }
n=$(pyq "$P8/fix/r2c.log" "len([r for r in rows if r.get('type')=='proxy-exit' and any(u.get('call_id')=='$P8CALL_A' for u in r.get('unresolved',[]))])")
[ "$n" -ge 1 ] || { sed -n '1,4p' "$P8/fix/r2c.log" >&2; fail "phase 63: the control reports NO unresolved entry — the phantom phase 62 measures absent is not reproduced, so the mutation is vacuous"; }
grep -q "UNRESOLVED" "$P8/fix/r2c.err" \
    || fail "phase 63: the control's stderr never reported the phantom"
# THE CONSEQUENCE, measured: the log this writer produces is not one this seat
# will LOAD (the loader refuses duplicates), so the pre-fix shape is now
# self-inconsistent — it cannot be resumed against its own record.
timeout 20 "$GATE" --upstream "$P8/upA.sse" --slave-file "$P8/fix/r2d.slave" \
    --log "$P8/fix/r2c.log" --deny get_weather --turns 1 2> "$P8/fix/r2d.err"
rc=$?
[ "$rc" -ne 0 ] || fail "phase 63: the main build LOADED the control's duplicated log — the writer's invariant and the loader's check have drifted apart again"
grep -q "MORE THAN ONCE" "$P8/fix/r2d.err" || fail "phase 63: the refusal of the control's log does not name the duplicate"
echo "   OK control caught: the pre-fix writer inflates one call into $n+ rows and reports a phantom UNRESOLVED at exit — and the record it writes is now one this seat REFUSES to load"

echo "== phase 64: P8-fix R3 — THE LOAD IS LINEAR, AND THE OVER-CAP WAY OUT IS NOT LOSSY"
# THE DEFECT (the review, probes 3+4): dmap_put/dmap_find were LINEAR scans, so
# the LOAD was O(n^2) — the reviewer MEASURED 50 K rows -> 11.3 s, 100 K -> 89.7
# s on their fixture, 200 K -> the over-cap refusal.  A record whose whole point
# is to accumulate made the seat's own successful prior runs the reason it
# cannot start.  THE DISCRIMINATOR IS MEASURED HERE, not assumed: on a 26.3 MB
# / 100,000-Row log THIS host gives 0.188 s on the build under test and 29.7 s
# on a one-off scratch build of the SAME source with only dmap_find reverted to
# the linear scan (identical output, and the reviewer's direction reproduced) —
# so the 20 s bound below fails the pre-fix shape by ~1.5x and the fixed one by
# ~100x, and the arm cannot pass by accident.
mkdir -p "$P8/fix/big"
python3 - "$P8/fix/big/log.jsonl" <<'PY'
import sys
with open(sys.argv[1], "w") as fh:
    for i in range(100000):
        fh.write('{"ts":"2026-01-01T00:00:00Z","session":null,"run":null,"turn":1,'
                 '"call_id":"call_big_%06d","true_name":"get_weather","args":"{}",'
                 '"pending":false,"outcome":"ok","verdict":"denied","author":"ops",'
                 '"refusal_name":"denied-by-ops","reason":"denied",'
                 '"denial_text":"(denied by host policy: denied)"}\n' % i)
PY
bytes=$(wc -c < "$P8/fix/big/log.jsonl")
[ "$bytes" -gt 20000000 ] || fail "phase 64: the big-log fixture is only $bytes bytes — the arm is not the review's shape"
timeout 20 "$GATE" --print-log-state "$P8/fix/big/log.jsonl" > "$P8/fix/big/state.txt" 2> "$P8/fix/big/state.err"
rc=$?
[ "$rc" -eq 0 ] || { tail -2 "$P8/fix/big/state.err" >&2; fail "phase 64: rc=$rc on a 100,000-row ($bytes-byte) log — the reviewer measured 89.7 s at this size on the pre-fix binary and the cap is 64 MiB, so a load inside 20 s is the linearity claim"; }
grep -q "rows=100000 calls=100000" "$P8/fix/big/state.txt" \
    || { head -1 "$P8/fix/big/state.txt" >&2; fail "phase 64: the digest does not report all 100,000 rows — the load did not do the work it is timed on"; }
echo "   OK linear: $bytes bytes / 100,000 rows load and digest inside the 20 s bound (the same fixture measured 0.188 s here, against 29.7 s for a scratch build with only the linear scan restored — and the reviewer measured 89.7 s on the pre-fix binary)"
# THE OVER-CAP REFUSAL MUST NAME A WAY OUT THAT KEEPS THE JOIN STATE.  A sparse
# file is enough: the cap is a SIZE check, taken before the file is read.
cp "$P8/fix/big/log.jsonl" "$P8/fix/big/over.log"
python3 - "$P8/fix/big/over.log" <<'PY'
import os, sys
with open(sys.argv[1], "ab") as fh:
    fh.truncate(64 * 1024 * 1024 + 1)
PY
timeout 60 "$GATE" --print-log-state "$P8/fix/big/over.log" > /dev/null 2> "$P8/fix/big/over.err"
rc=$?
[ "$rc" -ne 0 ] || fail "phase 64: an over-cap log LOADED (rc=0) — the size guard is gone"
grep -q "load cap" "$P8/fix/big/over.err" || fail "phase 64: the over-cap refusal does not name the cap"
grep -q "THE WAY OUT IS NOT LOSSY" "$P8/fix/big/over.err" \
    || { tail -2 "$P8/fix/big/over.err" >&2; fail "phase 64: the over-cap refusal does not name a recovery that PRESERVES the join state — the review's finding was that its only named way out LOST it"; }
# AND THE NAMED RECOVERY IS RUN, not merely printed: the compacted form (the
# DENIED rows alone, the predicate the refusal names) is a log this seat loads,
# with every denial's map entry intact — that is what makes the bound
# RECOVERABLE rather than self-defeating.
grep -F '"verdict":"denied"' "$P8/fix/big/log.jsonl" > "$P8/fix/big/compacted.jsonl"
n=$(wc -l < "$P8/fix/big/compacted.jsonl")
[ "$n" -eq 100000 ] || fail "phase 64: the compaction kept $n of 100000 denied rows — the named way out does not preserve the join state it is for"
timeout 20 "$GATE" --print-log-state "$P8/fix/big/compacted.jsonl" > "$P8/fix/big/cstate.txt" 2> /dev/null
rc=$?
[ "$rc" -eq 0 ] || fail "phase 64: the compacted log does not load (rc=$rc) — the refusal names a way out that does not exist"
grep -q "dmap=100000" "$P8/fix/big/cstate.txt" \
    || { head -1 "$P8/fix/big/cstate.txt" >&2; fail "phase 64: the compacted log reloaded with a different deny map — the recovery lost join state"; }
echo "   OK recoverable: the over-cap refusal names the DENIED-row compaction, and the gate RUNS it — all 100,000 denials are still in the rebuilt map"

echo "== phase 65: P8-fix R4 — A NON-REGULAR --log IS REFUSED AT THE DOOR (a FIFO used to HANG the seat silently)"
# THE DEFECT (the review, probe 3): log_load fopen'd whatever --log named.
# MEASURED by the reviewer: a FIFO blocked the open FOREVER with zero
# log-related output; /dev/null was accepted and a flush would have renamed a
# temp over the device node; a SYMLINK was replaced by the first flush, the
# record silently splitting in two; a directory died with a bare errno.
# EVERY proxy started here is TIME-BOUNDED (timeout -k), because the failure
# mode being gated IS a silent hang: an unbounded arm would hang the gate.
mkdir -p "$P8/fix/r4dir"
mkfifo "$P8/fix/r4fifo"
printf '{"ts":"2026-01-01T00:00:00Z","session":null,"run":null,"turn":1,"call_id":"call_L","true_name":"get_weather","args":"{}","pending":true,"outcome":null,"verdict":null}\n' > "$P8/fix/r4target.log"
cp "$P8/fix/r4target.log" "$P8/fix/r4target.before"
ln -sf "$P8/fix/r4target.log" "$P8/fix/r4link.log"
p8_r4() { # <tag> <log-path> <stderr-substring>
    local tag="$1" path="$2" want="$3"
    timeout -k 2 10 "$GATE" --upstream "$FIX/responses_simple.sse" \
        --slave-file "$P8/fix/r4-$tag.slave" --log "$path" --turns 1 \
        2> "$P8/fix/r4-$tag.err"
    local rc=$?
    [ "$rc" -eq 1 ] || { tail -2 "$P8/fix/r4-$tag.err" >&2; fail "phase 65: --log $tag gave rc=$rc (124 would be the HANG this check exists to remove; 0 would mean the seat served against it)"; }
    grep -q "IS NOT USABLE AS THE ONE LOG" "$P8/fix/r4-$tag.err" \
        || { tail -2 "$P8/fix/r4-$tag.err" >&2; fail "phase 65: the $tag refusal does not name the door check"; }
    grep -q "$want" "$P8/fix/r4-$tag.err" \
        || { tail -2 "$P8/fix/r4-$tag.err" >&2; fail "phase 65: the $tag refusal does not say WHAT is wrong (want '$want')"; }
    grep -q "REFUSES TO START" "$P8/fix/r4-$tag.err" || fail "phase 65: the $tag refusal is not the loud refusal"
    [ -e "$P8/fix/r4-$tag.slave" ] && fail "phase 65: the $tag refusal still published a slave path — it did not stop before serving"
    echo "   OK $tag: rc=$rc, named at the door, nothing served"
}
p8_r4 fifo "$P8/fix/r4fifo" "NOT A REGULAR FILE"
p8_r4 dir "$P8/fix/r4dir" "NOT A REGULAR FILE"
p8_r4 link "$P8/fix/r4link.log" "SYMLINK"
p8_r4 null /dev/null "NOT A REGULAR FILE"
# THE TWO SILENT CATASTROPHES THE DOOR CHECK EXISTS FOR, each measured after:
[ -p "$P8/fix/r4fifo" ] || fail "phase 65: the FIFO is gone — a refusal must not touch the object it refuses"
[ -c /dev/null ] || fail "phase 65: /dev/null is no longer a character device — a flush renamed a temp over it (the device-node catastrophe the review named)"
[ -L "$P8/fix/r4link.log" ] || fail "phase 65: the symlink was REPLACED by a regular file — the record would have split in two"
cmp -s "$P8/fix/r4target.log" "$P8/fix/r4target.before" \
    || fail "phase 65: the symlink's TARGET was modified by a refused run"
# THE CONTROL: the SAME FIFO against the pre-fix-shaped build (the load
# compiled out — it never looks at the path at all).  BOUNDED, so the gate
# itself never hangs on it: rc 124 IS the defect, and it is the asymmetry.
timeout -k 2 5 "$GATENOLOGLOAD" --upstream "$FIX/responses_simple.sse" \
    --slave-file "$P8/fix/r4ctl.slave" --log "$P8/fix/r4fifo" --turns 1 \
    2> "$P8/fix/r4ctl.err"
rc=$?
[ "$rc" -eq 124 ] || { cat "$P8/fix/r4ctl.err" >&2; fail "phase 65: the pre-fix-shaped build did NOT hang on the FIFO (rc=$rc) — the door check is not what removed the hang, so this arm proves nothing"; }
n=$(grep -c "IS NOT USABLE" "$P8/fix/r4ctl.err" || true)
[ "$n" = "0" ] || fail "phase 65: the control refused the FIFO — it does not reproduce the silent path"
echo "   OK control caught: the FIFO hangs the pre-fix-shaped build with ZERO log-related output (rc=124 under a 5 s bound, no message) — the door check is exactly what turns that silent hang into a loud refusal"

echo "== phase 66: P8-fix R5/R6b/R7 — a CARRIED row keeps its own reading, the fields are validated, and the CRLF normalization is SAID OUT LOUD"
# R5 (the review's probe 5): log_flush RECOMPUTED allow_scope from the CURRENT
# run's seats, so a row written under "no operator denial at this seat" was
# silently REWORDED by a later run — the record claiming a judgement another
# run made.  The arm below flushes the carried row with the CLAIM SEAT ARMED
# (the reviewer's exact direction: ops-only written, claim-armed flush).
python3 - "$P8/fix/allow.jsonl" <<'PY'
import json, sys
OPSSCOPE = ("seat-scoped: no operator denial at this seat; "
            "the in-guest floor and D2 still govern")
row = {"ts": "2026-01-01T00:00:00Z", "session": None, "run": None, "turn": 1,
       "call_id": "call_S", "true_name": "get_weather", "args": "{}",
       "pending": False, "outcome": "ok", "verdict": "allowed", "author": "ops",
       "allow_scope": OPSSCOPE, "refusal_name": None, "reason": None,
       "denial_text": None}
open(sys.argv[1], "w").write(json.dumps(row) + "\n")
PY
cp "$P8/fix/allow.jsonl" "$P8/fix/r5.log"
"$GATE" --upstream "$FIX/responses_simple.sse" --slave-file "$P8/fix/r5.slave" \
    --log "$P8/fix/r5.log" --calls-policy-dir "$CALLS_DIR" --turns 1 \
    2> "$P8/fix/r5.err" &
P8L=$!
PROXIES="$PROXIES $P8L"
wait_for_slave "$P8/fix/r5.slave" "$P8L" "$P8/fix/r5.err"
grep -q "seat ARMED" "$P8/fix/r5.err" \
    || { tail -3 "$P8/fix/r5.err" >&2; fail "phase 66: the claim seat did not arm — the recompute this phase exists to catch would be a no-op and the assert vacuous"; }
p8_drive "$(cat "$P8/fix/r5.slave")" "$P8/f1.json"
wait_for_proxy_exit "$P8L" "$P8/fix/r5.err"
wait "$P8L"
[ "$?" -eq 0 ] || fail "phase 66: the flush run exited nonzero"
grep -qF '"allow_scope":"seat-scoped: no operator denial at this seat; the in-guest floor and D2 still govern"' "$P8/fix/r5.log" \
    || { head -1 "$P8/fix/r5.log" >&2; fail "phase 66: the carried row's allow_scope was REWORDED by a run that judged nothing — the record now claims a claim-seat judgement that never happened"; }
n=$(grep -c "no claim refusal" "$P8/fix/r5.log" || true)
[ "$n" = "0" ] || fail "phase 66: the carried row now claims a claim-seat reading ($n row(s)) — the reword the review measured"
echo "   OK carried verbatim: with the claim seat ARMED, the carried row still reads exactly what its own run wrote"
# THE CONTROL: the same fixture, the same armed flush, the scope recomputed
cp "$P8/fix/allow.jsonl" "$P8/fix/r5ctl.log"
"$GATENOSCOPECARRY" --upstream "$FIX/responses_simple.sse" --slave-file "$P8/fix/r5ctl.slave" \
    --log "$P8/fix/r5ctl.log" --calls-policy-dir "$CALLS_DIR" --turns 1 \
    2> "$P8/fix/r5ctl.err" &
P8M=$!
PROXIES="$PROXIES $P8M"
wait_for_slave "$P8/fix/r5ctl.slave" "$P8M" "$P8/fix/r5ctl.err"
p8_drive "$(cat "$P8/fix/r5ctl.slave")" "$P8/f1.json"
wait_for_proxy_exit "$P8M" "$P8/fix/r5ctl.err"
wait "$P8M"
[ "$?" -eq 0 ] || fail "phase 66: the R5 control exited nonzero"
grep -q "no claim refusal" "$P8/fix/r5ctl.log" \
    || { head -1 "$P8/fix/r5ctl.log" >&2; fail "phase 66: the R5 control did NOT reword the carried scope — the mutation did not take, so the assert above proves nothing"; }
echo "   OK control caught: with the scope-carry compiled out the same flush REWORDS the row to claim the claim seat judged it — the reviewer's measured defect, reproduced on demand"
# R6b: `turn` is a whole number or the log refuses (3.7 used to load and then
# re-render differently; 1e100 was undefined through get_sint)
for bad in 3.7 1e100 -1 '"1"'; do
    python3 - "$P8/fix/turn.log" "$bad" <<'PY'
import json, sys
row = {"ts": "2026-01-01T00:00:00Z", "session": None, "run": None, "turn": 0,
       "call_id": "call_T", "true_name": "get_weather", "args": "{}",
       "pending": False, "outcome": None, "verdict": None}
raw = json.dumps(row).replace('"turn": 0', '"turn": ' + sys.argv[2])
open(sys.argv[1], "w").write(raw + "\n")
PY
    timeout 20 "$GATE" --print-log-state "$P8/fix/turn.log" > /dev/null 2> "$P8/fix/turn.err"
    rc=$?
    [ "$rc" -ne 0 ] || fail "phase 66: a row with turn=$bad LOADED (rc=0) — a field the writer only ever writes whole is accepted from the file"
done
grep -q "not an INTEGER\|negative" "$P8/fix/turn.err" \
    || fail "phase 66: the turn refusal does not name what a turn must be"
echo "   OK turn validated: 3.7, 1e100, -1 and a string are each REFUSED (the writer only ever writes a whole, non-negative turn)"
# R7: CRLF is ACCEPTED (a Windows copy is not corruption) and the
# normalization is REPORTED, not silent
python3 - "$P8/fix/crlf.log" <<'PY'
import sys
row = (b'{"ts":"2026-01-01T00:00:00Z","session":null,"run":null,"turn":1,'
       b'"call_id":"call_CR","true_name":"get_weather","args":"{}",'
       b'"pending":false,"outcome":null,"verdict":null}')
open(sys.argv[1], "wb").write(row + b"\r\n")
PY
cp "$P8/fix/crlf.log" "$P8/fix/crlf.before"
timeout 20 "$GATE" --print-log-state "$P8/fix/crlf.log" > "$P8/fix/crlf.out" 2> "$P8/fix/crlf.err"
rc=$?
[ "$rc" -eq 0 ] || { tail -2 "$P8/fix/crlf.err" >&2; fail "phase 66: a CRLF log was REFUSED (rc=$rc) — a Windows copy of the record is not corruption"; }
grep -q "ended CRLF" "$P8/fix/crlf.err" \
    || { cat "$P8/fix/crlf.err" >&2; fail "phase 66: the CRLF row was accepted SILENTLY — the loader must say that the file will be normalized"; }
grep -q "NORMALIZED to LF" "$P8/fix/crlf.err" || fail "phase 66: the CRLF notice does not say what happens on the next flush"
cmp -s "$P8/fix/crlf.log" "$P8/fix/crlf.before" || fail "phase 66: --print-log-state MODIFIED the file — it must only read"
echo "   OK CRLF: accepted, announced (line count + what the next flush does), and the read-only path leaves the file alone"
# THE TRUST BOUNDARY IS STATED WHERE A READER MEETS IT (the review's demand):
# in the --log usage the seat prints, not only in a source comment.
timeout 10 "$GATE" --nonsense 2> "$P8/fix/usage.err" > /dev/null
grep -q "TRUSTED INPUT" "$P8/fix/usage.err" \
    || { tail -5 "$P8/fix/usage.err" >&2; fail "phase 66: the seat's own usage does not state that the log is TRUSTED INPUT — the trust boundary must be stated where it is met"; }
grep -q "REGULAR FILE" "$P8/fix/usage.err" \
    || fail "phase 66: the usage does not state the regular-file requirement"
echo "   OK trust boundary stated: the seat's usage names the log as TRUSTED INPUT (structure checked, content trusted) and the regular-file rule"

echo "== phase 67: P8-fix EXTRA — THE WRITER/LOADER DRIFT: the seat could not load its OWN record from an UNARMED run"
# FOUND WHILE IMPLEMENTING R5 (not in the review's list, and NOT visible to it
# because every P8 arm reloads an ARMED log): the loader called log_str on
# `verdict`, which REFUSES AN ABSENT KEY — but the writer renders no
# verdict/author at all when no policy ran (the P2 row shape).  MEASURED before
# this fix: a log written by an unarmed run died on restart with "`verdict` is
# not a string", so the seat REFUSED TO START against its own successful
# record.  That is the self-lockout class the review's probe-4 property names,
# and it is exactly the writer/loader drift R2 requires to be gone.  The arm
# below uses a REAL unarmed run (never a hand-built row): the record is the
# seat's own output, and the property is that the seat can continue it.
# responses_tool.sse carries a real call, so the UNARMED row (verdict/author
# absent) is exercised: with responses_simple.sse there would be no call row at
# all and the arm would pass vacuously.
"$GATE" --upstream "$FIX/responses_tool.sse" --slave-file "$P8/fix/u1.slave" \
    --log "$P8/fix/unarmed.log" --turns 1 2> "$P8/fix/u1.err" &
P8N=$!
PROXIES="$PROXIES $P8N"
wait_for_slave "$P8/fix/u1.slave" "$P8N" "$P8/fix/u1.err"
drive_frame "$(cat "$P8/fix/u1.slave")"
wait_for_proxy_exit "$P8N" "$P8/fix/u1.err"
wait "$P8N"
[ "$?" -eq 0 ] || fail "phase 67: the unarmed run exited nonzero"
n=$(pyq "$P8/fix/unarmed.log" "len([r for r in rows if 'verdict' not in r and 'author' not in r and r.get('type') is None])")
[ "$n" -eq 1 ] || { head -2 "$P8/fix/unarmed.log" >&2; fail "phase 67: the unarmed run did not write the P2 row shape (no verdict/author) — the arm is not the drift it exists for"; }
before=$(wc -c < "$P8/fix/unarmed.log")
"$GATE" --upstream "$FIX/responses_tool.sse" --slave-file "$P8/fix/u2.slave" \
    --log "$P8/fix/unarmed.log" --turns 1 2> "$P8/fix/u2.err" &
P8O=$!
PROXIES="$PROXIES $P8O"
wait_for_slave "$P8/fix/u2.slave" "$P8O" "$P8/fix/u2.err"
drive_frame "$(cat "$P8/fix/u2.slave")"
wait_for_proxy_exit "$P8O" "$P8/fix/u2.err"
wait "$P8O"
rc2=$?
[ "$rc2" -eq 0 ] || { tail -3 "$P8/fix/u2.err" >&2; fail "phase 67: rc=$rc2 — the seat REFUSES TO START against its own UNARMED record (the drift: the writer omits verdict/author when no policy ran, and an absent key is not a shape log_str accepts)"; }
grep -q "log: LOADED 2 row(s)" "$P8/fix/u2.err" \
    || { tail -3 "$P8/fix/u2.err" >&2; fail "phase 67: the restart did not carry the unarmed record (its own row + the previous exit row)"; }
[ "$(wc -c < "$P8/fix/unarmed.log")" -gt "$before" ] \
    || fail "phase 67: the restart wrote nothing — the record did not continue"
# AND THE TOLERANCE IS NARROW: absent-or-null is accepted, a WRONG TYPE is not
python3 - "$P8/fix/badtype.log" <<'PY'
import sys
row = ('{"ts":"2026-01-01T00:00:00Z","session":null,"run":null,"turn":1,'
       '"call_id":"call_BT","true_name":"get_weather","args":"{}",'
       '"pending":false,"outcome":null,"verdict":5}')
open(sys.argv[1], "w").write(row + "\n")
PY
timeout 20 "$GATE" --print-log-state "$P8/fix/badtype.log" > /dev/null 2> "$P8/fix/badtype.err"
rc=$?
[ "$rc" -ne 0 ] || fail "phase 67: a row carrying a NUMBER in the verdict field LOADED — the optionality must be absent-or-null, not anything-goes"
grep -q "is not a string" "$P8/fix/badtype.err" \
    || { tail -2 "$P8/fix/badtype.err" >&2; fail "phase 67: the wrong-type refusal does not name the field type rule"; }
echo "   OK writer/loader drift closed: an unarmed run's own record loads and CONTINUES on restart (while a wrong-typed field still refuses) — the seat can no longer be locked out by its own successful run"

# ── P10: THE REAL LANE (the HTTP upstream, the endpoint from ENV) ───────────
#
# DIRECTION (stated up front): the live lane is a SECOND upstream arm, and the
# two failure shapes it must exclude are (i) a SILENT GREEN — an absent or
# unreachable endpoint must SKIP LOUDLY (exit 77, naming what was skipped and
# why), never pass — and (ii) a DRIFTING SEND BUFFER — the bytes the proxy
# POSTs must be EXACTLY the frame outbound_pass RETURNED (the same bytes
# --dump-requests records), so a live lane that re-renders the frame is caught
# by content.  The endpoint URL and the credential come from the ENVIRONMENT
# and NEVER cross into the guest: the chardev carries only the served SSE and
# the guest's own request frames.  The canned-file arm above is the CONTROL
# and stays BYTE-IDENTICAL (this section adds a lane beside it, never a change
# to it).
#
# THE THREE MEASUREMENTS the offline arm could not make (recorded here AND in
# the handoff result):
#   (a) INTERLEAVE — driven live (n=1 turn, 3 calls): the provider sets
#       parallel_tool_calls:true but SERIALIZES each function_call item on the
#       wire (added(A)->done(A) before added(B)); NO added(A) added(B)
#       done(B) done(A) interleave observed.  The P3-fix per-item buffers are
#       correct-but-not-stressed by THIS provider.
#   (b) SCHEMA HONORED — the injected tools array (justification REQUIRED) is
#       honored: the live model emitted the justification field, well-formed,
#       on every call; on a denial it read the denial text, did not blind-retry,
#       and pivoted to permitted exploration, folding the denial into its next
#       justifications.
#   (c) SEND BUFFER — asserted deterministically below (phase 71): the mock
#       endpoint captures the POST body, and it must EQUAL the dumped frame.
#
# NEW FIXTURE: tests/fixtures/responses_live_justified.sse is a RECORDED LIVE
# STREAM — captured from the live endpoint http://10.0.0.1:8321/v1/responses
# (model deepseek-v4-flash, served as deepseek-flash) on 2026-10-16 ~22:49Z,
# the request carrying the proxy's exact injected tools array (13 fx-verbs,
# justification REQUIRED).  It carries two function_call items — fx_read
# (/etc/hostname) then fx_ls (/etc), each WITH the required justification —
# and the provider SERIALIZES them (added->done per item, no interleave).
# It is used ONLY as the mock endpoint's served body in phase 71 (a COPY,
# never the shared fixture, never mutated).
#
# Phase 70: the LOUD SKIP (absent / unreachable / https / malformed).
# Phase 71: the mock endpoint (deterministic): send-buffer wiring + the
#           enforcement property over HTTP + the credential boundary.
# Phase 72: the REAL lane against the live provider — SKIPs loudly when the
#           endpoint is absent/unreachable (never a silent green), else runs
#           the whole loop and asserts the invariant, and its observation is
#           carried into the final PASS echo (P10-fix 5).
# Phase 73: THE P10-FIX — the liveness signalling of the lane: a
#           REACHABLE-BUT-BROKEN response is a LOUD NAMED failure (the pre-fix
#           shape was rc=0 with the bytes served), the HTTP HEADER BLOCK is
#           never served as the body, a credential embedded in the endpoint
#           URL is never printed, and the documented 32 MiB cap is the real
#           one.
LIVE_ENDPOINT="${FX_HOSTGATE_LIVE_ENDPOINT:-${FX_HOSTGATE_ENDPOINT:-}}"

# redact_url <url> — the URL AS IT MAY BE PRINTED (P10-fix SHOULD-FIX 3):
# userinfo and the query string are REDACTED, because a credential can ride in
# either and a message is not a place to print one.  The redaction is MARKED,
# never silent.
redact_url() {
    local u="$1" q="" scheme rest auth
    case "$u" in *\?*) q="?<redacted>" ;; esac
    u="${u%%\?*}"
    case "$u" in
        *://*@*)
            scheme="${u%%://*}://"
            rest="${u#*://}"
            auth="${rest%%/*}"
            u="$scheme<redacted>@${auth##*@}${rest#"$auth"}"
            ;;
    esac
    printf '%s%s' "$u" "$q"
}

# THE LIVE OBSERVATION, carried into the FINAL PASS ECHO (P10-fix
# NICE-TO-HAVE 5): phase 72's assertions are conditional on the live model
# actually calling a tool, so with n==0 calls they run against nothing — the
# arm proves NOTHING while the summary still reads as a pass.  A hard n==0 FAIL
# would flake against a non-deterministic model, so the absence is made
# VISIBLE: this line is printed in the PASS echo, where a reader cannot miss
# what the live arm did or did not exercise.
LIVE_STATUS="LIVE (phase 72): NOT RUN — no live endpoint was named"

# make_live_stub <script> <read-marker> <ls-marker> — the two-verb dispatch
# stub for the recorded live fixture (fx_read + fx_ls), each touching its OWN
# marker; anything else -> -32602 exactly as fx-verbs-server.c:2669-2674.
make_live_stub() {
    cat > "$1" <<PY
#!/usr/bin/env python3
import json, sys
MARKERS = {"fx_read": "$2", "fx_ls": "$3"}
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
            "serverInfo": {"name": "hostgate-live-stub", "version": "0"}}}),
            flush=True)
    elif m == "tools/call":
        name = (req.get("params") or {}).get("name")
        if name in MARKERS:
            with open(MARKERS[name], "a") as f:
                f.write("dispatched %s\n" % name)
            print(json.dumps({"jsonrpc": "2.0", "id": req.get("id"),
                              "result": {"content": [{"type": "text",
                                                      "text": "ok"}]}}),
                  flush=True)
        else:
            print(json.dumps({"jsonrpc": "2.0", "id": req.get("id"),
                              "error": {"code": -32602,
                                        "message": "unknown tool: %s" % name}}),
                  flush=True)
PY
    chmod +x "$1"
}

# make_mock_endpoint <script> <fixture> <bodyfile> <authfile> <portfile> — a
# minimal HTTP endpoint that serves a COPY of a fixture and CAPTURES the exact
# POST body and Authorization header the proxy sends (the (c) send-buffer
# witness and the credential-boundary witness).  serve_forever: the proxy's
# startup reachability probe connects and closes without a request, which the
# handler ignores.
make_mock_endpoint() {
    cat > "$1" <<PY
import http.server, sys
FIX, BODYF, AUTHF, PORTF = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    def do_POST(self):
        n = int(self.headers.get('Content-Length', '0') or '0')
        body = self.rfile.read(n)
        with open(BODYF, 'ab') as f:
            f.write(body)
            f.write(b'\n')
        with open(AUTHF, 'a') as f:
            f.write((self.headers.get('Authorization') or '') + '\n')
        data = open(FIX, 'rb').read()
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *a):
        pass
srv = http.server.HTTPServer(('127.0.0.1', 0), H)
with open(PORTF, 'w') as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
PY
    chmod +x "$1"
}

echo "== phase 70: P10 THE LOUD SKIP — absent / unreachable / https / malformed"
# (a) ABSENT: --http with no FX_HOSTGATE_ENDPOINT must exit 77 and NAME the
# skip — a silent green is the failure shape this arm excludes.
env -u FX_HOSTGATE_ENDPOINT -u FX_HOSTGATE_LIVE_ENDPOINT \
    "$GATE" --http --slave-file "$TMP/p10a.slave" --log "$TMP/p10a.log" --turns 1 \
    > /dev/null 2> "$TMP/p10a.err"
rc=$?
[ "$rc" -eq 77 ] || fail "phase 70a: --http with no endpoint env exited rc=$rc (want 77) — an absent endpoint must SKIP LOUDLY"
grep -q "SKIP (hostgate-http)" "$TMP/p10a.err" \
    || fail "phase 70a: the skip does not NAME itself (no 'SKIP (hostgate-http)')"
grep -q "FX_HOSTGATE_ENDPOINT" "$TMP/p10a.err" \
    || fail "phase 70a: the skip does not say WHAT is absent"
echo "   OK absent: rc=77, a named SKIP naming FX_HOSTGATE_ENDPOINT"
# (b) UNREACHABLE: a refused connect must skip loudly, not hang and not green.
FX_HOSTGATE_ENDPOINT="http://127.0.0.1:1/v1/responses" \
    "$GATE" --http --slave-file "$TMP/p10b.slave" --log "$TMP/p10b.log" --turns 1 \
    > /dev/null 2> "$TMP/p10b.err"
rc=$?
[ "$rc" -eq 77 ] || fail "phase 70b: an unreachable endpoint exited rc=$rc (want 77) — it must SKIP LOUDLY"
grep -q "unreachable" "$TMP/p10b.err" \
    || fail "phase 70b: the skip does not say the endpoint is UNREACHABLE"
echo "   OK unreachable: rc=77, the skip names 'unreachable'"
# (c) HTTPS: this build speaks plain HTTP (the tree's NO-TLS decision); a TLS
# endpoint is REFUSED LOUDLY, never half-supported.
FX_HOSTGATE_ENDPOINT="https://api.example.com/v1/responses" \
    "$GATE" --http --slave-file "$TMP/p10c.slave" --log "$TMP/p10c.log" --turns 1 \
    > /dev/null 2> "$TMP/p10c.err"
rc=$?
[ "$rc" -eq 77 ] || fail "phase 70c: an https endpoint exited rc=$rc (want 77) — it must REFUSE LOUDLY"
grep -q "https" "$TMP/p10c.err" \
    || fail "phase 70c: the refusal does not name the https endpoint"
echo "   OK https: rc=77, a named refusal naming 'https'"
# (d) MALFORMED: a non-URL endpoint must skip loudly, not crash silently.
FX_HOSTGATE_ENDPOINT="not a url" \
    "$GATE" --http --slave-file "$TMP/p10d.slave" --log "$TMP/p10d.log" --turns 1 \
    > /dev/null 2> "$TMP/p10d.err"
rc=$?
[ "$rc" -eq 77 ] || fail "phase 70d: a malformed endpoint exited rc=$rc (want 77)"
grep -q "SKIP (hostgate-http)" "$TMP/p10d.err" \
    || fail "phase 70d: the malformed-endpoint skip is not loud"
echo "   OK malformed: rc=77, a named skip"

echo "== phase 71: P10 THE MOCK ENDPOINT — send-buffer wiring + enforcement + credential boundary"
# A COPY of the recorded live fixture (NEVER the shared fixture, NEVER mutated):
# fx_read (call_00) + fx_ls (call_01), each justified.  fx_read is DENIED,
# fx_ls is ALLOWED — so the enforcement property has both directions in one
# run, served over the real HTTP lane.
cp "$FIX/responses_live_justified.sse" "$TMP/live-fixture.sse" \
    || fail "phase 71: cannot copy the live fixture"
[ -s "$FIX/responses_live_justified.sse" ] \
    || fail "phase 71: fixture responses_live_justified.sse missing — run make first / restore the fixture"
make_live_stub "$TMP/live_stub.py" "$TMP/marker-live-read" "$TMP/marker-live-ls"
make_mock_endpoint "$TMP/mock.py" "$TMP/live-fixture.sse" \
    "$TMP/mock-body.bin" "$TMP/mock-auth.txt" "$TMP/mock-port"
python3 "$TMP/mock.py" "$TMP/live-fixture.sse" "$TMP/mock-body.bin" \
    "$TMP/mock-auth.txt" "$TMP/mock-port" 2> "$TMP/mock.err" &
MOCK=$!
PROXIES="$PROXIES $MOCK"
for i in $(seq 1 100); do [ -s "$TMP/mock-port" ] && break; sleep 0.05; done
[ -s "$TMP/mock-port" ] || fail "phase 71: the mock endpoint never published its port"
MOCKPORT=$(cat "$TMP/mock-port")
mkdir -p "$TMP/cfg-live" "$TMP/data-live"
cat > "$TMP/cfg-live/config.dhall" <<DHALL
{ agents =
  [ { name = "fx"
    , agent_type = "agent"
    , mcp_servers = [ { command = "$TMP/live_stub.py", args = [] : List Text } ]
    }
  ]
}
DHALL
FX_HOSTGATE_ENDPOINT="http://127.0.0.1:$MOCKPORT/v1/responses" \
FX_HOSTGATE_KEY="test-secret-key-123" \
    "$GATE" --http --slave-file "$TMP/p71.slave" --log "$TMP/p71.log.jsonl" \
    --dump-requests "$TMP/p71.dump.jsonl" --deny fx_read --require-justification \
    --turns 2 2> "$TMP/p71.err" &
P71=$!
PROXIES="$PROXIES $P71"
wait_for_slave "$TMP/p71.slave" "$P71" "$TMP/p71.err"
DEV71=$(cat "$TMP/p71.slave")
FX_CHARDEV="$DEV71" FX_AGENT_CONFIG_DIR="$TMP/cfg-live" \
    FX_AGENT_DATA="$TMP/data-live" HOME="$TMP" \
    "$BIN" -p "inspect the guest" --agent fx --max-turns 2 --output text \
    > "$TMP/p71.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] || { sed -n '1,8p' "$TMP/p71.err" >&2; fail "phase 71: the HTTP-lane run rc=$rc"; }
wait_for_proxy_exit "$P71" "$TMP/p71.err"
wait "$P71"
prc=$?
[ "$prc" -eq 0 ] || fail "phase 71: the proxy exited rc=$prc over the HTTP lane"
kill "$MOCK" 2>/dev/null
# (c) THE SEND-BUFFER WIRING: the bytes POSTed to the endpoint are EXACTLY the
# dumped (returned) frames — one line per turn, byte-for-byte.  A live lane
# that re-rendered the frame would diverge here.
[ -s "$TMP/mock-body.bin" ] || fail "phase 71: the mock captured NO POST body — the HTTP lane never sent"
n=$(wc -l < "$TMP/mock-body.bin")
[ "$n" -eq 2 ] || fail "phase 71: expected 2 captured POST bodies (one per turn), got $n"
cmp -s "$TMP/p71.dump.jsonl" "$TMP/mock-body.bin" \
    || { echo "--- dump (what was RETURNED) ---"; cat "$TMP/p71.dump.jsonl"; echo "--- captured (what was SENT) ---"; cat "$TMP/mock-body.bin"; fail "phase 71: the POSTed body diverges from the returned/dumped frame — the live lane re-rendered the send buffer (SHOULD-FIX 4 regression)"; }
# the tools array is INJECTED into the model-facing frame (justification
# required) — the (b) schema reaches the live lane's wire
grep -q '"tools":\[.*"justification"' "$TMP/mock-body.bin" \
    || fail "phase 71: the POSTed frame carries no injected tools array with justification — the model was never told what is required"
# enforcement over HTTP: fx_read (denied) NEVER dispatches; fx_ls (allowed) DOES
[ ! -e "$TMP/marker-live-read" ] \
    || fail "phase 71: fx_read EXECUTED over the HTTP lane — the denied call crossed (a silent allow)"
[ -f "$TMP/marker-live-ls" ] \
    || fail "phase 71: fx_ls never dispatched over the HTTP lane — the allowed call did NOT execute (a proxy denying everything would pass the denied half)"
# the host log recorded the verdicts honestly, over the real HTTP lane
n=$(pyq "$TMP/p71.log.jsonl" "len([r for r in rows if r.get('true_name')=='fx_read' and r.get('verdict')=='denied' and r.get('refusal_name')=='denied-by-denylist'])")
[ "$n" -ge 1 ] || fail "phase 71: no denied row for fx_read over the HTTP lane"
n=$(pyq "$TMP/p71.log.jsonl" "len([r for r in rows if r.get('true_name')=='fx_ls' and r.get('verdict')=='allowed'])")
[ "$n" -ge 1 ] || fail "phase 71: no allowed row for fx_ls over the HTTP lane"
# THE CREDENTIAL BOUNDARY: the key reached ONLY the endpoint (the mock's
# Authorization header), never the guest, the log, the dump, or the proxy's
# own stderr.
grep -q "^Bearer test-secret-key-123$" "$TMP/mock-auth.txt" \
    || fail "phase 71: the mock did NOT receive 'Authorization: Bearer test-secret-key-123' — the credential never reached the endpoint"
for f in "$TMP/p71.err" "$TMP/p71.log.jsonl" "$TMP/p71.dump.jsonl" "$TMP/data-live"/sessions/*/messages.jsonl "$TMP/p71.out"; do
    if grep -q "test-secret-key-123" "$f" 2>/dev/null; then
        fail "phase 71: the credential LEAKED into $f — the key must never cross into the guest, the log, the dump or the proxy's stderr"
    fi
done
echo "   OK mock lane: POSTed bytes == the returned frame (byte-for-byte); the tools array (justification required) reached the wire; fx_read denied (never executed) / fx_ls allowed (executed); the credential went to the endpoint ONLY"

echo "== phase 72: P10 THE REAL LANE — the live provider (SKIPs loudly offline)"
# The one arm that needs the actual endpoint.  Absent/unreachable -> a LOUD
# SKIP (never a silent green, never a hang).  Reachable -> the whole loop runs
# against the live model and the invariant is asserted.
if [ -z "$LIVE_ENDPOINT" ]; then
    echo "   SKIP phase 72 (the real lane): FX_HOSTGATE_LIVE_ENDPOINT (or FX_HOSTGATE_ENDPOINT) is not set — no live endpoint was named, so the whole-loop-against-a-real-model arm cannot run"
    LIVE_STATUS="LIVE (phase 72): NOT RUN — no live endpoint was named, so the whole-loop-against-a-real-model arm did not execute"
elif ! python3 - "$LIVE_ENDPOINT" <<'PY'
import sys, socket, urllib.parse
u = urllib.parse.urlparse(sys.argv[1])
if u.scheme != "http":
    print("unreachable: %s is not a plain-http endpoint" % u.scheme); sys.exit(1)
try:
    s = socket.create_connection((u.hostname, u.port or 80), timeout=5)
    s.close()
    print("reachable")
except Exception as e:
    print("unreachable: %s" % e); sys.exit(1)
PY
then
    echo "   SKIP phase 72 (the real lane): $(redact_url "$LIVE_ENDPOINT") is unreachable — the live arm cannot run, and a substitute would measure a stand-in, not the provider"
    LIVE_STATUS="LIVE (phase 72): NOT RUN — the named endpoint is unreachable, and a substitute would measure a stand-in, not the provider"
else
    rm -f "$TMP/marker-live-write"
    # a phase-72 stub: fx_write (the DENIED verb) touches the write marker if it
    # EVER dispatches — the silent-allow instrument; anything else answers "ok"
    # (recorded, not asserted — a live model's own behaviour is an observation).
    cat > "$TMP/live_stub2.py" <<PY
#!/usr/bin/env python3
import json, sys
WRITE = "$TMP/marker-live-write"
OBS = "$TMP/live-obs.txt"
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
            "serverInfo": {"name": "hostgate-live2-stub", "version": "0"}}}),
            flush=True)
    elif m == "tools/call":
        name = (req.get("params") or {}).get("name")
        with open(OBS, "a") as f:
            f.write("dispatched %s\n" % name)
        if name == "fx_write":
            # the silent-allow witness: this must NEVER be reached under the
            # gate (the proxy rewrites a denied fx_write to fx_host_denied)
            with open(WRITE, "a") as f:
                f.write("dispatched fx_write\n")
            print(json.dumps({"jsonrpc": "2.0", "id": req.get("id"),
                              "result": {"content": [{"type": "text",
                                                      "text": "ok"}]}}),
                  flush=True)
        else:
            # refuse any other name (fx_host_denied included) with -32602,
            # exactly as fx-verbs-server.c:2669-2674 refuses an unknown name —
            # so the guest synthesizes the known "(tool call failed)" sentinel
            # and the echo-anomaly instrument sees the clean shape.
            print(json.dumps({"jsonrpc": "2.0", "id": req.get("id"),
                              "error": {"code": -32602,
                                        "message": "unknown tool: %s" % name}}),
                  flush=True)
PY
    chmod +x "$TMP/live_stub2.py"
    mkdir -p "$TMP/cfg-live2" "$TMP/data-live2"
    cat > "$TMP/cfg-live2/config.dhall" <<DHALL
{ agents =
  [ { name = "fx"
    , agent_type = "agent"
    , mcp_servers = [ { command = "$TMP/live_stub2.py", args = [] : List Text } ]
    }
  ]
}
DHALL
    # fx_write is DENIED; the prompt asks for a write.  Whatever the live model
    # does, the invariant is: fx_write never executes, and no denied true name
    # crosses into the transcript as a call name.
    FX_HOSTGATE_ENDPOINT="$LIVE_ENDPOINT" \
        "$GATE" --http --slave-file "$TMP/p72.slave" --log "$TMP/p72.log.jsonl" \
        --dump-requests "$TMP/p72.dump.jsonl" --deny fx_write \
        --require-justification --turns 2 2> "$TMP/p72.err" &
    P72=$!
    PROXIES="$PROXIES $P72"
    wait_for_slave "$TMP/p72.slave" "$P72" "$TMP/p72.err"
    DEV72=$(cat "$TMP/p72.slave")
    FX_CHARDEV="$DEV72" FX_AGENT_CONFIG_DIR="$TMP/cfg-live2" \
        FX_AGENT_DATA="$TMP/data-live2" HOME="$TMP" \
        "$BIN" -p "Write the text 'live-lane probe' to /tmp/live.txt using fx_write." \
        --agent fx --max-turns 2 --output text > "$TMP/p72.out" 2>&1
    rc=$?
    [ "$rc" -eq 0 ] || { sed -n '1,8p' "$TMP/p72.err" >&2; fail "phase 72: the live-lane run rc=$rc"; }
    wait_for_proxy_exit "$P72" "$TMP/p72.err"
    wait "$P72"
    prc=$?
    [ "$prc" -eq 0 ] || fail "phase 72: the proxy exited rc=$prc against the live endpoint"
    # THE INVARIANT, live: fx_write never executed, and no denied true name
    # crossed into the guest's transcript as a call name.
    [ ! -e "$TMP/marker-live-write" ] \
        || fail "phase 72: fx_write EXECUTED against the live endpoint — the denied call crossed (a silent allow)"
    TR72=$(ls "$TMP"/data-live2/sessions/*/messages.jsonl 2>/dev/null)
    [ -f "$TR72" ] || fail "phase 72: no guest transcript over the live lane"
    n=$(pyq "$TR72" "len([1 for r in rows for tc in (r.get('tool_calls') or []) if tc.get('name')=='fx_write'])")
    [ "$n" -eq 0 ] || fail "phase 72: the TRUE NAME fx_write crossed into the guest's transcript — THE INVARIANT IS BROKEN live"
    # OBSERVATIONS, printed (not asserted — a real model is non-deterministic):
    # what it called, whether it justified, and the denial rate the host log
    # recorded.
    n=$(pyq "$TMP/p72.log.jsonl" "len([r for r in rows if 'true_name' in r])")
    d=$(pyq "$TMP/p72.log.jsonl" "len([r for r in rows if r.get('verdict')=='denied'])")
    a=$(pyq "$TMP/p72.log.jsonl" "len([r for r in rows if r.get('verdict')=='allowed'])")
    echo "   LIVE observed: $n call(s) decoded; $d denied; $a allowed (the live model's own behaviour, recorded)"
    LIVE_STATUS="LIVE (phase 72): $n call(s) decoded, $d denied, $a allowed"
    if [ "$n" -eq 0 ]; then
        # VISIBLE, and not a FAIL: the model is non-deterministic, so refusing
        # to run would flake — but an arm whose assertions ran against nothing
        # must not read as an arm that proved something.
        echo "   WARNING phase 72: the live model made NO tool call this run — the invariant held TRIVIALLY and NO denial was exercised, so this arm proved NOTHING about the enforcement property (the live model declined the offered tool; a real observation, not a failure)"
        LIVE_STATUS="$LIVE_STATUS — THE LIVE ARM PROVED NOTHING (n=0: no call was made, so no denial was exercised)"
    fi
fi

echo "== phase 73: P10-FIX — a REACHABLE-BUT-BROKEN response is LOUD, the HEADER BLOCK is not the body, a URL credential is never printed"
# THE PRE-FIX SHAPE (measured by the P10 review against e0f0b86, with an
# ASAN+UBSAN build): an unframed response, an LF-only header block, a non-HTTP
# status line (ICY 200 OK), a lying Content-Length, a lying chunk size and a
# 34 MiB body each ended rc=0 with the bytes — or the whole header block —
# SERVED to the guest, which reads EOF as a synthesized FINISH: the run
# "successfully" ends with the model answer lost or never produced.  That is
# the availability half of "never a silent green", and every one of those
# shapes is a LOUD NAMED failure now, while a CLEAN close-delimited 200 (this
# endpoint's own shape) still passes.
cp "$FIX/responses_simple.sse" "$TMP/p73-body.sse" \
    || fail "phase 73: cannot copy the body fixture (a COPY, never the shared fixture)"
[ -s "$TMP/p73-body.sse" ] || fail "phase 73: fixture responses_simple.sse missing — run make first / restore the fixture"

# make_evil_endpoint <script> — a raw socket endpoint that answers EVERY
# connection with ONE canned byte sequence chosen by <mode> (no HTTP library:
# the point is to control the exact bytes on the wire, including the broken
# ones).  The proxy's startup reachability probe connects and sends nothing,
# which is absorbed by the same recv/sendall path.
make_evil_endpoint() {
    cat > "$1" <<'PY'
import socket, sys
MODE, PORTF, BODYF = sys.argv[1], sys.argv[2], sys.argv[3]
BODY = open(BODYF, 'rb').read()
HEAD = (b'HTTP/1.0 200 OK\r\nContent-Type: text/event-stream\r\n'
        b'Connection: close\r\n\r\n')
RAW = {
    # no CRLFCRLF anywhere: no header block, so nothing agrees a framing
    'garbage': b'this is not an HTTP response at all, and it never ends a header',
    # LF-only header lines: again no CRLFCRLF terminator
    'lfonly': b'HTTP/1.0 200 OK\nContent-Type: text/event-stream\n\n' + BODY,
    # a status line that is not HTTP at all (the pre-fix code skipped the
    # status check entirely here)
    'icystatus': b'ICY 200 OK\r\nContent-Type: text/event-stream\r\n\r\n' + BODY,
    # Content-Length claims 100000; the socket closes after 10 bytes
    'cllie': (b'HTTP/1.0 200 OK\r\nContent-Type: text/event-stream\r\n'
              b'Content-Length: 100000\r\n\r\n' + BODY[:10]),
    # the chunk size line claims 10 bytes, 5 arrive, then EOF: no zero chunk
    'chunklie': (b'HTTP/1.0 200 OK\r\nContent-Type: text/event-stream\r\n'
                 b'Transfer-Encoding: chunked\r\n\r\nA\r\n' + BODY[:5] + b'\r\n'),
    # a well-framed 200 (close-delimited) with NO body: the lane is DEAD, and
    # only a note can say so — no framing rule is violated
    'empty': HEAD,
    # a well-framed close-delimited 200 carrying the body: MUST still pass
    'clean': HEAD + BODY,
}
RESP = HEAD + b'x' * (33 * 1024 * 1024) if MODE == 'cap' else RAW[MODE]
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('127.0.0.1', 0))
srv.listen(8)
with open(PORTF, 'w') as f:
    f.write(str(srv.getsockname()[1]))
while True:
    c, _ = srv.accept()
    try:
        c.settimeout(10)
        c.recv(65536)
        c.sendall(RESP)
        # a graceful close (FIN) AFTER draining: closing with the request still
        # unread sends RST, which DISCARDS the bytes this arm is about
        c.shutdown(socket.SHUT_WR)
        while c.recv(65536):
            pass
    except Exception:
        pass
    finally:
        c.close()
PY
    chmod +x "$1"
}
make_evil_endpoint "$TMP/p73-evil.py"

# ── (3) A CREDENTIAL EMBEDDED IN THE ENDPOINT URL ─────────────────────────
# Pre-fix this printed the raw URL: 'SKIP ...: bad port in
# http://user:secretpass@127.0.0.1:1/v1/responses'.  This lane takes its
# credential from FX_HOSTGATE_KEY only, so the URL-embedded form is refused BY
# NAME — and the refusal prints the REDACTED URL.
FX_HOSTGATE_ENDPOINT="http://user:secretpass@127.0.0.1:1/v1/responses" \
    "$GATE" --http --slave-file "$TMP/p73u.slave" --log "$TMP/p73u.log" --turns 1 \
    > /dev/null 2> "$TMP/p73u.err"
rc=$?
[ "$rc" -eq 77 ] || fail "phase 73 (url credential): rc=$rc (want 77) — a credential embedded in the endpoint URL is refused by name"
grep -qF "<redacted>@" "$TMP/p73u.err" \
    || fail "phase 73 (url credential): the refusal does not MARK the redaction (no '<redacted>@') — a silent redaction is not a redaction a reader can trust"
if grep -q "secretpass" "$TMP/p73u.err"; then
    fail "phase 73 (url credential): THE URL-EMBEDDED CREDENTIAL WAS PRINTED VERBATIM to stderr (SHOULD-FIX 3)"
fi
echo "   OK url credential: rc=77, a named refusal, the userinfo prints as <redacted>@ — the credential never reaches a message"

# ── (3b) HEADER-INJECTION HARDENING: a CR/LF in the URL or the key ────────
FX_HOSTGATE_ENDPOINT=$'http://127.0.0.1:1/v1/responses\r\nX-Inject: yes' \
    "$GATE" --http --slave-file "$TMP/p73crlf.slave" --log "$TMP/p73crlf.log" --turns 1 \
    > /dev/null 2> "$TMP/p73crlf.err"
rc=$?
[ "$rc" -eq 77 ] || fail "phase 73 (crlf endpoint): rc=$rc (want 77) — a CR/LF in the endpoint must be refused, not written into a request head"
grep -qF "contains a CR or LF" "$TMP/p73crlf.err" \
    || fail "phase 73 (crlf endpoint): the refusal does not name the CR/LF"
FX_HOSTGATE_ENDPOINT="http://127.0.0.1:1/v1/responses" \
FX_HOSTGATE_KEY=$'secret-key\r\nX-Inject: yes' \
    "$GATE" --http --slave-file "$TMP/p73crlfk.slave" --log "$TMP/p73crlfk.log" --turns 1 \
    > /dev/null 2> "$TMP/p73crlfk.err"
rc=$?
[ "$rc" -eq 77 ] || fail "phase 73 (crlf key): rc=$rc (want 77) — a CR/LF in the key must be refused, not sent in a header"
grep -qF "FX_HOSTGATE_KEY" "$TMP/p73crlfk.err" \
    || fail "phase 73 (crlf key): the refusal does not name FX_HOSTGATE_KEY"
if grep -q "secret-key" "$TMP/p73crlfk.err"; then
    fail "phase 73 (crlf key): the KEY ITSELF was printed in the refusal"
fi
echo "   OK header-injection hardening: a CR/LF in the endpoint URL or in the key is REFUSED by name (rc=77), never sent, never printed"

# ── (1)+(2)+(4) THE FRAMING ARMS ──────────────────────────────────────────
# arm = <mode>:<want-rc>:<the words the note must carry>.  Every BROKEN framing
# must exit rc=1 with a named failure (the pre-fix shape was rc=0 with the
# bytes served); the two WELL-FRAMED shapes must still exit rc=0 — a framing
# check that also refuses the clean close-delimited 200 would have "fixed" the
# silent green by breaking the lane it protects.
for arm in "garbage:1:no HTTP response header block" \
           "lfonly:1:no HTTP response header block" \
           "icystatus:1:did not answer HTTP" \
           "cllie:1:closed mid-stream" \
           "chunklie:1:malformed or truncated chunked body" \
           "cap:1:exceeds 33554432 bytes" \
           "clean:0:turn 1: served" \
           "empty:0:WARNING (hostgate-http)"; do
    mode="${arm%%:*}"
    armrest="${arm#*:}"
    rw="${armrest%%:*}"
    want="${armrest#*:}"
    rm -f "$TMP/p73-$mode.port" "$TMP/p73-$mode.err" "$TMP/p73-$mode.capture"
    python3 "$TMP/p73-evil.py" "$mode" "$TMP/p73-$mode.port" "$TMP/p73-body.sse" \
        2> "$TMP/p73-$mode.ep.err" &
    EPID=$!
    PROXIES="$PROXIES $EPID"
    for i in $(seq 1 100); do [ -s "$TMP/p73-$mode.port" ] && break; sleep 0.05; done
    [ -s "$TMP/p73-$mode.port" ] \
        || fail "phase 73 ($mode): the evil endpoint never published its port"
    EPORT=$(cat "$TMP/p73-$mode.port")
    FX_HOSTGATE_ENDPOINT="http://127.0.0.1:$EPORT/v1/responses" \
        timeout 120 "$GATE" --http --slave-file "$TMP/p73-$mode.slave" \
        --log "$TMP/p73-$mode.log.jsonl" --turns 1 \
        > /dev/null 2> "$TMP/p73-$mode.err" &
    P73=$!
    PROXIES="$PROXIES $P73"
    wait_for_slave "$TMP/p73-$mode.slave" "$P73" "$TMP/p73-$mode.err"
    capture_frame "$(cat "$TMP/p73-$mode.slave")" "$TMP/p73-$mode.capture"
    wait "$P73"
    prc=$?
    if [ "$prc" -ne "$rw" ]; then
        sed -n '1,6p' "$TMP/p73-$mode.err" >&2
        fail "phase 73 ($mode): the proxy exited rc=$prc (want $rw) — a reachable-but-broken response is a SILENT GREEN, the pre-fix shape (or, for a well-framed response, the framing check is refusing a clean lane)"
    fi
    grep -qF "$want" "$TMP/p73-$mode.err" \
        || fail "phase 73 ($mode): the proxy does not SAY '$want'"
    kill "$EPID" 2>/dev/null
    if [ "$rw" -eq 1 ]; then
        grep -qF "FAIL (hostgate-http)" "$TMP/p73-$mode.err" \
            || fail "phase 73 ($mode): the failure does not NAME itself as an HTTP-lane failure"
        echo "   OK $mode: rc=1 with the NAMED failure '$want' (pre-fix: rc=0, the bytes served to the guest)"
    else
        echo "   OK $mode: rc=0 — a well-framed response still passes"
    fi
done

# ── (2) THE HEADER BLOCK IS NOT THE BODY, and a well-framed body still serves ─
# 'clean' is the control for the loop above: the SAME endpoint, the SAME
# request, a well-framed close-delimited 200 — it must pass, and the stream the
# GUEST READS must not begin with the HTTP header block.  Captured raw, the
# pre-fix stream began 'HTTP/1.0 200 OK\r\nContent-Type: text/event-stream…'.
[ "$(wc -c < "$TMP/p73-clean.capture")" -gt 0 ] \
    || fail "phase 73 (clean): a well-framed close-delimited 200 served NOTHING — the framing check is refusing a clean response"
head -c 5 "$TMP/p73-clean.capture" > "$TMP/p73-clean.head5"
if [ "$(cat "$TMP/p73-clean.head5")" = "HTTP/" ]; then
    fail "phase 73 (clean): the guest's stream BEGINS WITH A STATUS LINE — the HTTP header block is being served as the body (SHOULD-FIX 2)"
fi
if grep -q '^HTTP/' "$TMP/p73-clean.capture"; then
    fail "phase 73 (clean): the served stream carries an HTTP status line — the header block was not stripped"
fi
head -c 60 "$TMP/p73-body.sse" > "$TMP/p73-want.head60"
head -c 60 "$TMP/p73-clean.capture" > "$TMP/p73-got.head60"
cmp -s "$TMP/p73-want.head60" "$TMP/p73-got.head60" \
    || { echo "--- served ---"; head -c 120 "$TMP/p73-clean.capture"; echo; echo "--- body fixture ---"; head -c 120 "$TMP/p73-body.sse"; echo; fail "phase 73 (clean): the served stream does not begin with the BODY's own first bytes — the header block (or a prefix) is being served"; }
grep -qF "response.completed" "$TMP/p73-clean.capture" \
    || fail "phase 73 (clean): the served stream lost response.completed"
# and the whole stream is the BODY, byte for byte: no header block, no prefix,
# nothing dropped (the transparency the offline arm asserts, over HTTP)
cmp -s "$TMP/p73-body.sse" "$TMP/p73-clean.capture" \
    || fail "phase 73 (clean): the served stream is not byte-identical to the body fixture ($(wc -c < "$TMP/p73-clean.capture") vs $(wc -c < "$TMP/p73-body.sse") bytes)"
echo "   OK clean: a well-framed close-delimited 200 still passes (rc=0) and the guest's stream is the BODY byte-for-byte, never a status line"

# ── (1v) A 200 WITH NO TERMINAL EVENT IS A DEAD LANE — said LOUDLY ────────
# 'empty' is well framed (nothing to refuse), so the framing checks cannot fail
# it: what must NOT happen is a silent green.  The proxy says so, and the run
# still ends rc=0 — a live provider that returns an empty 200 is a dead lane,
# not a proxy failure, and the WARNING is what makes it visible.
[ ! -s "$TMP/p73-empty.capture" ] \
    || fail "phase 73 (empty): a 200 with no body served $(wc -c < "$TMP/p73-empty.capture") bytes (want 0) — the header block is being served as the body"
grep -qF "WARNING (hostgate-http)" "$TMP/p73-empty.err" \
    || fail "phase 73 (empty): a 200 carrying no response.completed was SILENT — the dead lane must say so (SHOULD-FIX 1(v))"
echo "   OK empty: a well-framed 200 with no body serves 0 bytes (headers stripped) and the dead lane is NAMED with a WARNING"

# ── (3) THE QUERY IS NOT PRINTED: a REAL HTTP server, a queried endpoint ──
# The startup note printed the path WITH its query.  This arm drives the same
# real-HTTP-server lane phase 71 uses, with a credential-shaped query.
make_mock_endpoint "$TMP/p73-mock.py" "$TMP/p73-body.sse" "$TMP/p73-mock-body.bin" \
    "$TMP/p73-mock-auth.txt" "$TMP/p73-mock-port"
python3 "$TMP/p73-mock.py" "$TMP/p73-body.sse" "$TMP/p73-mock-body.bin" \
    "$TMP/p73-mock-auth.txt" "$TMP/p73-mock-port" 2> "$TMP/p73-mock.err" &
MOCK73=$!
PROXIES="$PROXIES $MOCK73"
for i in $(seq 1 100); do [ -s "$TMP/p73-mock-port" ] && break; sleep 0.05; done
[ -s "$TMP/p73-mock-port" ] || fail "phase 73 (query): the mock endpoint never published its port"
MOCK73PORT=$(cat "$TMP/p73-mock-port")
FX_HOSTGATE_ENDPOINT="http://127.0.0.1:$MOCK73PORT/v1/responses?api_key=topsecret-query" \
    timeout 120 "$GATE" --http --slave-file "$TMP/p73q.slave" --log "$TMP/p73q.log.jsonl" \
    --turns 1 > /dev/null 2> "$TMP/p73q.err" &
P73Q=$!
PROXIES="$PROXIES $P73Q"
wait_for_slave "$TMP/p73q.slave" "$P73Q" "$TMP/p73q.err"
grep -qF "?<redacted>" "$TMP/p73q.err" \
    || fail "phase 73 (query): the startup note does not MARK the redacted query (no '?<redacted>')"
if grep -q "topsecret-query" "$TMP/p73q.err"; then
    fail "phase 73 (query): THE QUERY WAS PRINTED VERBATIM in the startup note (SHOULD-FIX 3)"
fi
capture_frame "$(cat "$TMP/p73q.slave")" "$TMP/p73q.capture"
wait "$P73Q"
prc=$?
[ "$prc" -eq 0 ] || { sed -n '1,6p' "$TMP/p73q.err" >&2; fail "phase 73 (query): the proxy exited rc=$prc against a real HTTP server"; }
if grep -q '^HTTP/' "$TMP/p73q.capture"; then
    fail "phase 73 (query): a REAL HTTP server's header block was served as the body"
fi
grep -qF "response.completed" "$TMP/p73q.capture" \
    || fail "phase 73 (query): the served stream over a real HTTP server lost response.completed"
kill "$MOCK73" 2>/dev/null
echo "   OK query: the startup note redacts the query (?<redacted>, never 'topsecret-query'), the real server's response is clean-framed, and the header block is not served"

# ── S1: THE HOST-TOOL REGISTRY + host_time, END TO END ─────────────────────
#
# THE SHAPE (the design record's, not re-litigated here): a host-executed tool
# call is an ORDINARY function_call in the proxied stream.  call_judge runs
# IDENTICALLY for a host tool and a guest verb — denial does NOT fork per
# executor, and the denied arm below drives the EXISTING fx_host_denied path —
# and only on the ALLOWED path does a registry lookup decide "execute here"
# instead of "forward verbatim to the guest".  The result reaches the model
# through the EXISTING outbound substitution, keyed on call_id.
#
# DIRECTION (stated up front, and it is the reason for the mutation blind):
# AN EXECUTOR THAT IS MISSING IS A SILENT DEGRADATION.  The host never runs the
# call, the guest answers -32602 for a name that is no guest verb, the model is
# handed "(tool call failed)" — and every policy line in the record still looks
# protective (verdict allowed, one row, no anomaly).  So the arms assert the
# WIRE (the dumped model-facing frame), never the exit status, and the
# FH_MUTANT_NO_EXEC build must be caught THERE.
#
# THE ASYMMETRY PAIR: (a) the real build EXECUTES and the next request's frame
# carries the REAL host result substituted over the guest's sentinel; (a') the
# PINNED PRE-S1 PROXY — built from a PINNED REVISION, never HEAD (the
# test_outcome.sh lesson: HEAD becomes the fixed source the moment this lands
# and every asymmetry here goes vacuous) — serves the SAME fixture through the
# same guest loop and the sentinel crosses UNSUBSTITUTED.  If that pinned
# source is unavailable (shallow clone) or identical to the working tree, the
# arm SKIPS OUT LOUD; the fixed half is asserted unconditionally either way.
#
# WHAT S1 DOES NOT CLAIM: host_time takes NO arguments of its own, so the
# plan's #1 risk — a host call silently permitted because its ARGUMENT matched
# no class row — is NOT exercised here.  It arrives with the classed tools.
PRES1_REV=835ac49
S1TOOL="host_time"
S1CALL="call_00_DgJfXOD0j0bvOV7jB0tl0124"
# restated HERE, independently of the source (the phase-26 discipline: two
# edits have to agree before a re-pin can pass unnoticed)
S1_PIN="06b64025cc9d7f6435e35e931c84dcae6eaf646a930218c7bdca953e8d44c55a"
S1_COLL_PIN="88638ce0cf6d71e4b4bd0890724e935597dd8f656c295501dc53a859df32c34a"

# make_refuse_stub <script> <marker> — the guest lane's MCP server for S1: it
# touches the marker for EVERY tools/call (the witness that the call CROSSED to
# the guest — the plan's n_tool_calls > 0 precondition) and answers -32602, the
# real verbs server's refusal for a name that is no verb
# (fx-verbs-server.c:2669-2674).  Zero guest change.
make_refuse_stub() { # <script-path> <marker-path>
    cat > "$1" <<PY
#!/usr/bin/env python3
import json, sys
MARKER = "$2"
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
            "serverInfo": {"name": "hostgate-refuse-stub", "version": "0"}}}),
            flush=True)
    elif m == "tools/call":
        name = (req.get("params") or {}).get("name")
        with open(MARKER, "a") as f:
            f.write("guest dispatched %s\n" % name)
        print(json.dumps({"jsonrpc": "2.0", "id": req.get("id"),
                          "error": {"code": -32602,
                                    "message": "unknown tool: %s" % name}}),
              flush=True)
PY
    chmod +x "$1"
}

# s1_run <gate> <tag> <fixture> [extra argv...] — ONE whole guest loop through
# a bounded proxy over the S1 fixture, with a FRESH FX_AGENT_DATA dir and a
# fresh config/stub per probe (never a shared one).  Sets S1_RC (the proxy),
# S1_GUEST_RC, S1_DIR, S1_ERR, S1_LOG, S1_DUMP, S1_MARKER, S1_DATA.
s1_run() {
    local gate="$1" tag="$2" fixt="$3"
    shift 3
    local d="$TMP/s1-$tag"
    mkdir -p "$d/data" "$d/cfg"
    make_refuse_stub "$d/stub.py" "$d/marker"
    cat > "$d/cfg/config.dhall" <<DHALL
{ agents =
  [ { name = "fx"
    , agent_type = "agent"
    , mcp_servers = [ { command = "$d/stub.py", args = [] : List Text } ]
    }
  ]
}
DHALL
    "$gate" --upstream "$fixt" --slave-file "$d/slave" --log "$d/log.jsonl" \
        --dump-requests "$d/dump.jsonl" "$@" --turns 2 2> "$d/proxy.err" &
    local p=$!
    PROXIES="$PROXIES $p"
    wait_for_slave "$d/slave" "$p" "$d/proxy.err"
    local dev
    dev=$(cat "$d/slave")
    FX_CHARDEV="$dev" FX_AGENT_CONFIG_DIR="$d/cfg" \
    FX_AGENT_DATA="$d/data" HOME="$d" \
        timeout 120 "$BIN" -p "s1 probe" --agent fx --max-turns 2 --output text \
        > "$d/guest.out" 2>&1
    S1_GUEST_RC=$?
    wait_for_proxy_exit "$p" "$d/proxy.err"
    wait "$p"
    S1_RC=$?
    S1_DIR="$d"; S1_ERR="$d/proxy.err"; S1_LOG="$d/log.jsonl"
    S1_DUMP="$d/dump.jsonl"; S1_MARKER="$d/marker"; S1_DATA="$d/data"
}

# s1_out_n <dump> <predicate over `o`> — count the function_call_output entries
# in the DUMPED (model-facing) frames for the S1 call_id whose output matches
# the predicate.
s1_out_n() {
    python3 - "$1" "$2" "$S1CALL" <<'PY'
import json, sys
dump, pred, cid = sys.argv[1], sys.argv[2], sys.argv[3]
n = 0
for line in open(dump):
    line = line.strip()
    if not line:
        continue
    f = json.loads(line)
    for it in f.get("input", []):
        if it.get("type") == "function_call_output" and it.get("call_id") == cid:
            o = it.get("output") or ""
            if eval(pred):
                n += 1
print(n)
PY
}

echo "== phase 74: S1 THE REGISTRY — a SECOND closed list, pinned, and disjoint from the guest's"
# The registry is a compiled-in table BESIDE the guest mirror, printed with its
# pin so a reader can tell "what the guest can do" from "what the host executes"
# at rest.  The pin is restated HERE independently of the source.  S2 appends
# host_cat (the first classed tool), so the list and pin are re-pinned.
S1TOOLS="host_time
host_cat"
"$GATE" --print-host-tools > "$TMP/s1-tools.txt" 2>/dev/null \
    || fail "phase 74: --print-host-tools failed"
"$GATE" --print-host-tools-sha > "$TMP/s1-tools.sha" 2>/dev/null \
    || fail "phase 74: --print-host-tools-sha failed"
[ "$(cat "$TMP/s1-tools.txt")" = "$S1TOOLS" ] \
    || fail "phase 74: the host-tool registry is '$(cat "$TMP/s1-tools.txt")', want exactly '$S1TOOLS' — the closed list drifted"
got=$(cat "$TMP/s1-tools.sha")
[ "$got" = "$S1_PIN" ] \
    || fail "phase 74: the registry hashes to $got, the gate restates $S1_PIN — the table was edited without a re-pin"
"$GATE" --print-catalog > "$TMP/s1-verbs.txt" 2>/dev/null
for h in $S1TOOLS; do
    if grep -qxF "$h" "$TMP/s1-verbs.txt"; then
        fail "phase 74: '$h' is ALSO in the pinned guest catalog — the two lists are not disjoint, so the pins do not separate the executors"
    fi
done
echo "   OK registry: two host tools (host_time, host_cat), pinned at $S1_PIN and disjoint from the 13 pinned guest verbs"

echo "== phase 75: S1 (a) ALLOWED -> EXECUTED -> SUBSTITUTED, and the pinned PRE-S1 control crosses UNSUBSTITUTED"
# The REAL build: the call is judged (denylist armed, host_time NOT on it ->
# allowed), the registry EXECUTES it, the item still crosses verbatim (the
# guest dispatches it and answers -32602), and the NEXT request's frame carries
# the REAL host result where the guest's sentinel was.
s1_run "$GATE" real "$FIX/responses_host_time.sse" --deny fx_write
[ "$S1_GUEST_RC" -eq 0 ] || { sed -n '1,10p' "$S1_ERR" >&2; fail "phase 75: the guest run rc=$S1_GUEST_RC"; }
[ "$S1_RC" -eq 0 ] || fail "phase 75: the proxy exited rc=$S1_RC"
grep -q "host-execute call_id=" "$S1_ERR" \
    || fail "phase 75: the proxy never marked the host execution (no 'host-execute') — the executor did not run"
grep -q "guest dispatched $S1TOOL" "$S1_MARKER" 2>/dev/null \
    || fail "phase 75: the guest never dispatched the call — it did not cross to the guest (the n_tool_calls>0 precondition)"
# THE SHAPE, not the exit status: the dumped frame's output for THIS call is a
# host wall clock, never the guest's sentinel.
n=$(s1_out_n "$S1_DUMP" "'(host_time:' in o")
[ "$n" -ge 1 ] || { cat "$S1_DUMP" >&2; fail "phase 75: the model-facing frame carries NO host result for $S1CALL — the substitution never fired"; }
n=$(s1_out_n "$S1_DUMP" "o == '(tool call failed)'")
[ "$n" -eq 0 ] || fail "phase 75: the model-facing frame STILL carries the guest's sentinel for $S1CALL — the host result did not replace it"
# THE RECORD: one row, allowed, exec=host, and its outcome is the result the
# model actually read (not the sentinel the join saw first).
n=$(pyq "$S1_LOG" "len([r for r in rows if r.get('call_id')=='$S1CALL' and r.get('verdict')=='allowed' and r.get('exec')=='host' and r.get('pending')==False and '(host_time:' in (r.get('outcome') or '')])")
[ "$n" -eq 1 ] || { grep -F "$S1CALL" "$S1_LOG" >&2; fail "phase 75: the log does not carry exactly one allowed exec=host row for $S1CALL whose outcome is the host result"; }
# the call crossed with its TRUE NAME (host calls are never rewritten) and the
# guest recorded its own refusal — both halves of "ordinary function_call".
grep -q "$S1TOOL" "$S1_DATA"/sessions/*/messages.jsonl \
    || fail "phase 75: the guest transcript does not carry the TRUE name $S1TOOL — an allowed host call must cross un-rewritten"
grep -q "tool call failed" "$S1_DATA"/sessions/*/messages.jsonl \
    || fail "phase 75: the guest transcript carries no refusal for the host tool — the guest did not dispatch it"
echo "   OK substituted: allowed -> host-execute -> the dumped next request carries the real wall clock over the guest's sentinel; the log row is allowed + exec=host + outcome = that result"

# THE PRE-FIX CONTROL: THE PINNED PRE-S1 PROXY (a PINNED REVISION, never HEAD),
# serving the SAME fixture through the SAME guest loop.
PRES1_SKIP=""
PREDL=""
mkdir -p "$TMP/pres1"
if ! git -C "$ROOT" cat-file -e "$PRES1_REV^{commit}" 2>/dev/null; then
    PRES1_SKIP="pinned revision $PRES1_REV unavailable (shallow clone or rewritten history)"
elif ! git -C "$ROOT" show "$PRES1_REV:tools/fx-hostgate.c" > "$TMP/pres1/fx-hostgate.c" 2>/dev/null; then
    PRES1_SKIP="cannot extract tools/fx-hostgate.c at $PRES1_REV"
elif cmp -s "$TMP/pres1/fx-hostgate.c" "$ROOT/tools/fx-hostgate.c"; then
    PRES1_SKIP="the pinned pre-S1 source is IDENTICAL to the working tree — the asymmetry would compare the code to itself"
else
    PREDL="${DATALOG_DIR:-}"
    if [ -z "$PREDL" ] && [ -e "$ROOT/../datalog-dafsa/zig-out/lib/libdatalog.so" ]; then
        PREDL="$ROOT/../datalog-dafsa"
    fi
    if [ -z "$PREDL" ] && [ -e "$HOME/fixpoint-linux/datalog-dafsa/zig-out/lib/libdatalog.so" ]; then
        PREDL="$HOME/fixpoint-linux/datalog-dafsa"
    fi
    [ -n "$PREDL" ] || PRES1_SKIP="no datalog sibling is resolvable, so the pinned proxy cannot be linked"
fi
if [ -z "$PRES1_SKIP" ]; then
    cc -std=c11 -O2 -Wall -Wextra \
        -I"$ROOT/src" -I"$ROOT/src/agent" -I"$ROOT/src/vendor/dhall-c" \
        -I"$ROOT/src/vendor/yyjson" -I"$ROOT/build/include" \
        -I"$ROOT/src/vendor/tomlc99" -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE \
        -o "$TMP/pres1/fx-hostgate" "$TMP/pres1/fx-hostgate.c" \
        "$ROOT/src/vendor/dhall-c/sha256.c" "$ROOT/src/vendor/yyjson/yyjson.c" \
        -L"$PREDL/zig-out/lib" -Wl,-rpath,"$PREDL/zig-out/lib" -ldatalog \
        2> "$TMP/pres1/cc.err" \
        || PRES1_SKIP="the pinned pre-S1 source does not compile ($(tail -1 "$TMP/pres1/cc.err"))"
fi
if [ -n "$PRES1_SKIP" ]; then
    echo "   SKIP phase 75 (pre-fix control): $PRES1_SKIP — the ASYMMETRY half did not run, so what the pinned proxy does with this fixture is UNMEASURED here (the fixed half above is asserted either way)"
else
    s1_run "$TMP/pres1/fx-hostgate" pres1 "$FIX/responses_host_time.sse" --deny fx_write
    [ "$S1_GUEST_RC" -eq 0 ] || { sed -n '1,10p' "$S1_ERR" >&2; fail "phase 75 (control): the guest run rc=$S1_GUEST_RC"; }
    [ "$S1_RC" -eq 0 ] || fail "phase 75 (control): the pinned proxy exited rc=$S1_RC"
    grep -q "guest dispatched $S1TOOL" "$S1_MARKER" 2>/dev/null \
        || fail "phase 75 (control): the call never reached the guest through the pinned proxy — the control is not the same scenario"
    # THE ASYMMETRY: the SAME fixture, the SAME guest loop, and the sentinel
    # crosses UNSUBSTITUTED (the pinned proxy has no host registry at all).
    n=$(s1_out_n "$S1_DUMP" "o == '(tool call failed)'")
    [ "$n" -ge 1 ] || { cat "$S1_DUMP" >&2; fail "phase 75 (control): the pinned pre-S1 proxy carried no sentinel — the control does not reproduce the pre-fix shape"; }
    n=$(s1_out_n "$S1_DUMP" "'(host_time:' in o")
    [ "$n" -eq 0 ] || fail "phase 75 (control): the pinned pre-S1 proxy carried a host result — the substitution above is not this slice's doing"
    n=$(pyq "$S1_LOG" "len([r for r in rows if r.get('exec')])")
    [ "$n" -eq 0 ] || fail "phase 75 (control): the pinned pre-S1 proxy wrote a row with an exec field — it has no exec field"
    echo "   OK asymmetry: the SAME fixture crosses with the sentinel UNSUBSTITUTED through the pinned pre-S1 proxy ($PRES1_REV) — the substitution is this slice's doing, not the scenario's"
fi

echo "== phase 76: S1 (b) --deny host_time — the EXISTING denial path, and NO executor run"
# The deny decision must NOT fork per executor: a denied host call takes the
# same path as a denied guest verb — the fx_host_denied rewrite, the deny-map
# substitution, the denylist author — and the host NEVER runs it (the dispatch
# marker is absent).  A host tool judged by a different rule would be a second
# gate.
s1_run "$GATE" deny "$FIX/responses_host_time.sse" --deny "$S1TOOL"
[ "$S1_GUEST_RC" -eq 0 ] || { sed -n '1,10p' "$S1_ERR" >&2; fail "phase 76: the guest run rc=$S1_GUEST_RC"; }
[ "$S1_RC" -eq 0 ] || fail "phase 76: the proxy exited rc=$S1_RC"
grep -q "host-execute call_id=" "$S1_ERR" \
    && fail "phase 76: the proxy EXECUTED a denied host call — the deny decision forked per executor (a second gate)"
grep -q "guest dispatched fx_host_denied" "$S1_MARKER" 2>/dev/null \
    || fail "phase 76: the guest did not receive the RESERVED name — the denial was not the existing one"
n=$(pyq "$S1_LOG" "len([r for r in rows if r.get('call_id')=='$S1CALL' and r.get('verdict')=='denied' and r.get('author')=='denylist' and r.get('refusal_name')=='denied-by-denylist' and not r.get('exec')])")
[ "$n" -eq 1 ] || { grep -F "$S1CALL" "$S1_LOG" >&2; fail "phase 76: the denied host call's row is not the ordinary denylist denial (author/refusal) with no exec field"; }
n=$(s1_out_n "$S1_DUMP" "o.startswith('(denied by host policy:')")
[ "$n" -ge 1 ] || fail "phase 76: the model-facing frame does not carry the denial text — the existing substitution did not fire"
n=$(s1_out_n "$S1_DUMP" "'(host_time:' in o")
[ "$n" -eq 0 ] || fail "phase 76: a host result crossed for a DENIED call"
echo "   OK denied, not executed: the existing fx_host_denied rewrite + denial-text substitution, the denylist author, and NO host-execute marker"

echo "== phase 77: S1 (c) A COLLIDING HOST TOOL NAME IS REFUSED AT STARTUP (and its blind executes it)"
# A host tool named after a guest verb is TWO EXECUTORS UNDER ONE NAME: the
# host runs it and the guest dispatches it.  The refusal is at startup, before
# the slave path is published (the P4 posture, extended in the SAME loop).
# The colliding build is the SAME table with ONE name changed AND its pin
# re-pinned, so the refusal that fires is the COLLISION and not a stale pin.
got=$("$GATEHOSTCOLL" --print-host-tools-sha 2>/dev/null)
[ "$got" = "$S1_COLL_PIN" ] \
    || fail "phase 77: the colliding build's registry pin is '$got', the gate restates $S1_COLL_PIN — a stale pin would make the refusal prove the wrong thing"
[ "$got" != "$S1_PIN" ] \
    || fail "phase 77: the colliding build carries the REAL registry pin — the name override did not reach the table"
"$GATEHOSTCOLL" --print-host-tools 2>/dev/null | grep -qxF "fx_read" \
    || fail "phase 77: the colliding build's registry does not carry fx_read — the arm does not build the collision"
rm -f "$TMP/s1-coll.slave"
"$GATEHOSTCOLL" --upstream "$FIX/responses_host_time.sse" \
    --slave-file "$TMP/s1-coll.slave" --log "$TMP/s1-coll.log" --turns 1 \
    > /dev/null 2> "$TMP/s1-coll.err"
rc=$?
[ "$rc" -eq 1 ] || fail "phase 77: the colliding registry exited rc=$rc (want 1) — it must REFUSE"
grep -q "COLLIDES with catalog verb" "$TMP/s1-coll.err" \
    || fail "phase 77: the refusal does not name the collision"
grep -q "REFUSING TO START" "$TMP/s1-coll.err" \
    || fail "phase 77: the refusal is not loud"
[ ! -s "$TMP/s1-coll.slave" ] \
    || fail "phase 77: the slave path was published BEFORE the refusal — the refusal came too late to be the only moment it could be said"
# THE MUTATION BLIND: the collision check compiled out with the SAME colliding
# name — the proxy STARTS and the colliding call is EXECUTED BY THE HOST while
# the guest dispatches the same name.  The gate catches the silent allow by the
# dispatch marker AND the guest's own dispatch.
sed "s/$S1TOOL/fx_read/g" "$FIX/responses_host_time.sse" > "$TMP/s1-fxread.sse"
s1_run "$GATEHOSTNOCOLL" coll "$TMP/s1-fxread.sse" --deny fx_status
[ "$S1_GUEST_RC" -eq 0 ] || { sed -n '1,10p' "$S1_ERR" >&2; fail "phase 77: the blind's guest run rc=$S1_GUEST_RC"; }
[ "$S1_RC" -eq 0 ] || fail "phase 77: the blind exited rc=$S1_RC — it must START (that is the whole failure)"
grep -q "host-execute call_id=" "$S1_ERR" \
    || fail "phase 77: the blind did not EXECUTE the colliding call — the arm is vacuous"
n=$(pyq "$S1_LOG" "len([r for r in rows if r.get('true_name')=='fx_read' and r.get('exec')=='host'])")
[ "$n" -ge 1 ] || fail "phase 77: the blind's log carries no exec=host row for the colliding name"
grep -q "guest dispatched fx_read" "$S1_MARKER" 2>/dev/null \
    || fail "phase 77: the guest did not dispatch the colliding name — the double execution was not measured"
echo "   OK collision: refused at startup (before the slave path), and the check-compiled-out build STARTS and executes fx_read while the guest dispatches it too — the silent allow the refusal prevents"

echo "== phase 78: S1 (d) MUTATION BLIND FH_MUTANT_NO_EXEC — the sentinel CROSSES (silent degradation)"
# The registry lookup compiled out of the allowed path.  Everything looks
# protective — verdict allowed, one row, exit 0 — and the model is handed the
# guest's own "(tool call failed)" in place of the result.  This is the arm the
# DIRECTION exists for: the wire capture is the only witness.
s1_run "$GATENOEXEC" noexec "$FIX/responses_host_time.sse" --deny fx_write
[ "$S1_GUEST_RC" -eq 0 ] || { sed -n '1,10p' "$S1_ERR" >&2; fail "phase 78: the blind's guest run rc=$S1_GUEST_RC"; }
[ "$S1_RC" -eq 0 ] || fail "phase 78: the blind exited rc=$S1_RC — the degradation is SILENT to the exit status, by construction"
n=$(s1_out_n "$S1_DUMP" "o == '(tool call failed)'")
[ "$n" -ge 1 ] || { cat "$S1_DUMP" >&2; fail "phase 78: the blind did NOT forward the sentinel — the arm does not reproduce the degradation"; }
n=$(s1_out_n "$S1_DUMP" "'(host_time:' in o")
[ "$n" -eq 0 ] || fail "phase 78: a host result crossed in the blind — the registry lookup is not what was blinded"
n=$(pyq "$S1_LOG" "len([r for r in rows if r.get('exec')])")
[ "$n" -eq 0 ] || fail "phase 78: the blind wrote an exec field — the executor is supposed to be absent"
n=$(pyq "$S1_LOG" "len([r for r in rows if r.get('call_id')=='$S1CALL' and r.get('verdict')=='allowed'])")
[ "$n" -eq 1 ] || fail "phase 78: the blind's row is not the protective 'allowed' one — the degradation shape is not the one the direction names"
echo "   OK blind caught: rc=0, verdict allowed, NO exec row, and '(tool call failed)' crosses on the wire in place of the result — an absent executor is a SILENT DEGRADATION, caught only by the capture"

echo "== phase 79: S1 THE INSTRUMENT EXTENDS — an EXECUTED host call whose substitution never fires is REPORTED"
# The other direction of the same instrument (the pre-fix control of phase 20 is
# the deny case): the host really ran the call, and the next request frame
# arrives WITHOUT the function_call_output — the substitution window closes
# unfired.  A record that stayed silent here would be the silent degradation
# itself, so the anomaly row must appear, naming the call by its tool NAME (a
# result in a name field would read as a call the model never made).
D79="$TMP/s1-unres"
mkdir -p "$D79"
"$GATE" --upstream "$FIX/responses_host_time.sse" --slave-file "$D79/slave" \
    --log "$D79/log.jsonl" --deny fx_write --turns 2 2> "$D79/err" &
P79=$!
PROXIES="$PROXIES $P79"
wait_for_slave "$D79/slave" "$P79" "$D79/err"
# TWO bare request frames (the bound phases' driver): the first decodes and
# EXECUTES the served call, the second carries no output for it.
for turn79 in 1 2; do
    drive_frame "$(cat "$D79/slave")"
done
wait_for_proxy_exit "$P79" "$D79/err"
wait "$P79"
prc=$?
[ "$prc" -eq 0 ] || fail "phase 79: the proxy exited rc=$prc"
grep -q "host-execute call_id=" "$D79/err" \
    || fail "phase 79: the call never executed — the arm does not reproduce the window"
n=$(pyq "$D79/log.jsonl" "len([r for r in rows if r.get('type')=='unresolved-substitution' and r.get('call_id')=='$S1CALL' and r.get('true_name')=='$S1TOOL'])")
[ "$n" -eq 1 ] || { grep "unresolved" "$D79/log.jsonl" >&2; fail "phase 79: an EXECUTED host call whose substitution never fired produced NO anomaly row — the instrument does not extend to the exec map, so this degradation would be silent"; }
grep -q "EXECUTED ON THE HOST on turn 1" "$D79/err" \
    || fail "phase 79: the anomaly is not said out loud on stderr either"
echo "   OK instrument: an executed host call whose outbound substitution never fires is REPORTED (one unresolved-substitution row naming the tool) — the silent degradation is made loud"

echo "== phase 80: S1 ONE OUTSIDE EFFECT PER call_id — a RESUME does not re-execute, and the exec row is carried BYTE-FOR-BYTE"
# The record keeps ONE row per call_id, so the executor runs at most ONCE per
# call_id — including across a restart, where the log is the join state: a
# re-served item is the upstream repeating a call, never a second one.  A
# re-execution here would be a duplicate outside effect (a second HTTP POST, in
# the tools this registry is for) with no row to say so.
D80="$TMP/s1-resume"
mkdir -p "$D80"
cp "$TMP/s1-real/log.jsonl" "$D80/log.jsonl"
cp "$D80/log.jsonl" "$D80/before.jsonl"
head -1 "$D80/before.jsonl" > "$D80/before1"
"$GATE" --upstream "$FIX/responses_host_time.sse" --slave-file "$D80/slave" \
    --log "$D80/log.jsonl" --deny fx_write --turns 1 2> "$D80/err" &
P80=$!
PROXIES="$PROXIES $P80"
wait_for_slave "$D80/slave" "$P80" "$D80/err"
grep -q "exec map with 1" "$D80/err" \
    || fail "phase 80: the restart did not rebuild the exec map from the record — a resumed run's replayed output would cross UNSUBSTITUTED"
drive_frame "$(cat "$D80/slave")"
wait_for_proxy_exit "$P80" "$D80/err"
wait "$P80"
prc=$?
[ "$prc" -eq 0 ] || fail "phase 80: the resumed proxy exited rc=$prc"
grep -q "ALREADY EXECUTED ON THE HOST" "$D80/err" \
    || fail "phase 80: the resumed run re-served the call and did not say it was already executed"
grep -q "host-execute call_id=" "$D80/err" \
    && fail "phase 80: the resumed run EXECUTED the call AGAIN — a re-served call_id is not a second call (a duplicate outside effect)"
head -1 "$D80/log.jsonl" > "$D80/after1"
cmp -s "$D80/before1" "$D80/after1" \
    || { diff "$D80/before1" "$D80/after1" >&2; fail "phase 80: the carried host-executed row was REWORDED by the reload — a record must keep its own reading of which side ran"; }
n=$(pyq "$D80/log.jsonl" "len([r for r in rows if r.get('call_id')=='$S1CALL'])")
[ "$n" -eq 1 ] || fail "phase 80: the resumed run left $n rows for one call_id (the record's one-row rule)"
echo "   OK resume: the exec map is rebuilt (1 key), the re-served call is NOT executed again, and the carried row is byte-identical"

echo "== phase 81: S1-fix (A1) an EXEC -> DENY policy flip drops the execution reading, and the log still LOADS"
# THE DEFECT (the S1 review's finding A: REPRODUCED against the pre-fix binary,
# and the two arms here are its two directions).  A1: run 1 with --deny
# fx_write EXECUTES host_time (row: allowed + exec=host + the clock as
# outcome); run 2 resumes the SAME log under --deny host_time, so the re-served
# call is REFUSED and row_call_record refreshes the verdict IN PLACE — and
# before this fix that refresh left exec/outcome behind, so the seat wrote a
# row that says DENIED *and* exec=host.  Run 3 then REFUSED TO START on the
# seat's own record ("these two readings cannot both be this seat's") — the
# P8-fix self-lockout class, through the new field.  Both halves are asserted:
# the refreshed row must not claim an execution it now refuses, and the third
# run must LOAD.
D81="$TMP/s1-fix-a1"
mkdir -p "$D81"
p8_frame "$D81/plain.json"
p8_frame "$D81/out.json" fc "$S1TOOL" "$S1CALL" '{}' out - "$S1CALL" '(tool call failed)'
# run 1 — EXECUTES (one turn suffices: the served item is judged and dispatched
# at its own done event).
"$GATE" --upstream "$FIX/responses_host_time.sse" --slave-file "$D81/slave1" \
    --log "$D81/log.jsonl" --deny fx_write --turns 1 2> "$D81/err1" &
P81A=$!
PROXIES="$PROXIES $P81A"
wait_for_slave "$D81/slave1" "$P81A" "$D81/err1"
p8_drive "$(cat "$D81/slave1")" "$D81/plain.json"
wait_for_proxy_exit "$P81A" "$D81/err1"
wait "$P81A"
r81a=$?
[ "$r81a" -eq 0 ] || fail "phase 81: run 1 exited rc=$r81a"
n=$(pyq "$D81/log.jsonl" "len([r for r in rows if r.get('call_id')=='$S1CALL' and r.get('verdict')=='allowed' and r.get('exec')=='host'])")
[ "$n" -eq 1 ] || { grep -F "$S1CALL" "$D81/log.jsonl" >&2; fail "phase 81: run 1 did not leave the allowed exec=host row this arm flips — nothing executed, so the arm proves nothing"; }
# run 2 — the FLIP: the same call is now DENIED, and the re-serve refreshes the
# carried row rather than opening a second one.
"$GATE" --upstream "$FIX/responses_host_time.sse" --slave-file "$D81/slave2" \
    --log "$D81/log.jsonl" --deny "$S1TOOL" --turns 1 2> "$D81/err2" &
P81B=$!
PROXIES="$PROXIES $P81B"
wait_for_slave "$D81/slave2" "$P81B" "$D81/err2"
p8_drive "$(cat "$D81/slave2")" "$D81/out.json"
wait_for_proxy_exit "$P81B" "$D81/err2"
wait "$P81B"
r81b=$?
[ "$r81b" -eq 0 ] || { tail -3 "$D81/err2" >&2; fail "phase 81: run 2 (the flip) exited rc=$r81b"; }
grep -q "refreshing the row's verdict IN PLACE" "$D81/err2" \
    || fail "phase 81: the resumed run did not reach the in-place verdict refresh — the arm is not the policy flip"
grep -q "host-execute call_id=" "$D81/err2" \
    && fail "phase 81: run 2 EXECUTED a call its policy denies — the deny branch must not reach the executor"
n=$(pyq "$D81/log.jsonl" "len([r for r in rows if r.get('call_id')=='$S1CALL' and r.get('verdict')=='denied' and not r.get('exec') and not r.get('outcome')])")
[ "$n" -eq 1 ] || { grep -F "$S1CALL" "$D81/log.jsonl" >&2; fail "phase 81: the refreshed row is not a clean denied row — it still claims an execution (exec/outcome) that THIS run refused, which is a record the loader refuses and this seat then cannot load"; }
# the deny and exec maps must never both hold the call_id: the loaded state
# says so, and (the headline) the loader ACCEPTS the record the seat wrote.
timeout 30 "$GATE" --print-log-state "$D81/log.jsonl" > "$D81/state.txt" 2> "$D81/state.err"
r81s=$?
[ "$r81s" -eq 0 ] || { cat "$D81/state.err" >&2; fail "phase 81: the loader REFUSED (rc=$r81s) a log the seat itself just wrote — the self-lockout"; }
grep -q "exec=0" "$D81/state.txt" \
    || { cat "$D81/state.txt" >&2; fail "phase 81: the loaded state still rebuilds an exec-map key for a row this run DENIED — the two maps both hold the call_id"; }
# run 3 — the real third process: it must START and serve.
"$GATE" --upstream "$FIX/responses_host_time.sse" --slave-file "$D81/slave3" \
    --log "$D81/log.jsonl" --deny "$S1TOOL" --turns 1 2> "$D81/err3" &
P81C=$!
PROXIES="$PROXIES $P81C"
wait_for_slave "$D81/slave3" "$P81C" "$D81/err3"
grep -q "log: LOADED" "$D81/err3" \
    || fail "phase 81: run 3 did not load the carried record"
p8_drive "$(cat "$D81/slave3")" "$D81/out.json"
wait_for_proxy_exit "$P81C" "$D81/err3"
wait "$P81C"
r81c=$?
[ "$r81c" -eq 0 ] || fail "phase 81: the third run exited rc=$r81c"
grep -q "host-execute call_id=" "$D81/err3" \
    && fail "phase 81: run 3 executed a call its policy denies"
echo "   OK flip to deny: the refreshed row is denied with NO exec/outcome, the exec map no longer holds the key, and a THIRD run LOADS and serves (pre-fix: the same two runs wrote a row the seat refused to load)"

echo "== phase 82: S1-fix (A2) a DENY -> EXEC policy flip does NOT execute, and the model is told the carried denial"
# A2, the serious direction: run 1 DENIES host_time (row: denied, join still
# open); run 2 resumes the SAME log under --deny fx_write, so the re-served
# call is ALLOWED this run — and row_call_record returns the carried DENIED row
# unchanged ("a repeat never weakens a carried verdict").  Before this fix
# host_dispatch's guard looked only at r->exec, so the HOST EXECUTED a call
# whose durable record says DENIED, while the outbound leg (deny precedence)
# handed the model the run-1 denial text: the model was told "denied by host
# policy" for a call that had just run, and the instrument stayed silent.  The
# carried verdict must bind the EXECUTOR, not only the row.
D82="$TMP/s1-fix-a2"
mkdir -p "$D82"
p8_frame "$D82/plain.json"
p8_frame "$D82/out.json" fc "$S1TOOL" "$S1CALL" '{}' out - "$S1CALL" '(tool call failed)'
# run 1 — DENIED.
"$GATE" --upstream "$FIX/responses_host_time.sse" --slave-file "$D82/slave1" \
    --log "$D82/log.jsonl" --deny "$S1TOOL" --turns 1 2> "$D82/err1" &
P82A=$!
PROXIES="$PROXIES $P82A"
wait_for_slave "$D82/slave1" "$P82A" "$D82/err1"
p8_drive "$(cat "$D82/slave1")" "$D82/plain.json"
wait_for_proxy_exit "$P82A" "$D82/err1"
wait "$P82A"
r82a=$?
[ "$r82a" -eq 0 ] || fail "phase 82: run 1 exited rc=$r82a"
n=$(pyq "$D82/log.jsonl" "len([r for r in rows if r.get('call_id')=='$S1CALL' and r.get('verdict')=='denied' and not r.get('exec') and r.get('pending')==True])")
[ "$n" -eq 1 ] || { grep -F "$S1CALL" "$D82/log.jsonl" >&2; fail "phase 82: run 1 did not leave a PENDING denied row for $S1CALL — the arm is not the shape whose substitution window the resumed run closes"; }
# run 2 — the FLIP: this run's judge ALLOWS the call the record refused.
"$GATE" --upstream "$FIX/responses_host_time.sse" --slave-file "$D82/slave2" \
    --log "$D82/log.jsonl" --deny fx_write --turns 1 \
    --dump-requests "$D82/dump2.jsonl" 2> "$D82/err2" &
P82B=$!
PROXIES="$PROXIES $P82B"
wait_for_slave "$D82/slave2" "$P82B" "$D82/err2"
p8_drive "$(cat "$D82/slave2")" "$D82/out.json"
wait_for_proxy_exit "$P82B" "$D82/err2"
wait "$P82B"
r82b=$?
[ "$r82b" -eq 0 ] || { tail -3 "$D82/err2" >&2; fail "phase 82: run 2 (the flip) exited rc=$r82b"; }
# THE DISCRIMINATOR: this run's judge allowed the call and the EXECUTOR refused
# it on the carried verdict.  Without this note the arm could pass for the
# trivial reason ("this run denied it too").
grep -q "is RECORDED DENIED" "$D82/err2" \
    || { tail -5 "$D82/err2" >&2; fail "phase 82: the resumed run did not refuse the execution on the CARRIED verdict — this arm cannot tell 'the executor refused a recorded denial' from 'the judge denied it again'"; }
grep -q "host-execute call_id=" "$D82/err2" \
    && fail "phase 82: the resumed run EXECUTED a call its own durable record says was DENIED — an outside effect behind a refusing row, and the outbound leg then tells the model it was denied"
n=$(pyq "$D82/log.jsonl" "len([r for r in rows if r.get('call_id')=='$S1CALL' and r.get('verdict')=='denied' and r.get('author')=='denylist' and not r.get('exec')])")
[ "$n" -eq 1 ] || { grep -F "$S1CALL" "$D82/log.jsonl" >&2; fail "phase 82: the carried denied row was weakened or given an exec field by the allowing run"; }
# THE MODEL-FACING LEG agrees with the record: the denial text, never a clock.
n=$(s1_out_n "$D82/dump2.jsonl" "o.startswith('(denied by host policy:')")
[ "$n" -ge 1 ] || { cat "$D82/dump2.jsonl" >&2; fail "phase 82: the model-facing frame does not carry the carried denial text — the substitution leg disagrees with the record"; }
n=$(s1_out_n "$D82/dump2.jsonl" "'(host_time:' in o")
[ "$n" -eq 0 ] || fail "phase 82: a host result crossed for a call the record says was DENIED"
echo "   OK flip to allow: the executor refuses the carried DENIED verdict (no host-execute), the row stays denied with no exec field, and the model reads the denial"

echo "== phase 83: S1-fix (B) a crafted exec row that is not verdict=allowed is REFUSED at startup"
# REFUTED CLAIM (the review's finding B): the loader's exec refusals covered
# unknown bindings, denied+exec and exec-without-outcome — but a row carrying
# exec="host" + an outcome and NO verdict field loaded CLEANLY.  This seat can
# only ever write exec on the ALLOWED path of an armed policy, so that shape is
# text it never writes; MEASURED pre-fix: it armed the exec map ("exec map with
# 1"), the outbound leg substituted the file's text as the call's own result,
# and the same crafted row for the fixture's real call_id SUPPRESSED the real
# execution (the re-serve hits the exec guard) — a hand-edited log could both
# suppress an outside effect and put words in the model's mouth.  One refusal
# now covers it (verdict must BE allowed, which subsumes the denied case).
# NOTE the residual this does NOT close: the loader checks STRUCTURE, never
# CONTENT — a structurally valid outcome is trusted text, exactly as a denial's
# denial_text is (asserted on the seat's own usage text below).
D83="$TMP/s1-fix-b"
mkdir -p "$D83"
python3 - "$D83/mint.jsonl" <<'PY'
import json, sys
# structurally valid in every field the writer renders, EXCEPT that no verdict
# was ever rendered — the shape only a hand edit produces.
row = {"ts": "2026-01-01T00:00:00Z", "session": None, "run": None, "turn": 1,
       "call_id": "call_S1FIX_MINT", "true_name": "host_time", "args": "{}",
       "pending": True, "outcome": "ATTACKER-FABRICATED-RESULT", "exec": "host"}
open(sys.argv[1], "w").write(json.dumps(row) + "\n")
PY
rm -f "$D83/mint.slave"
timeout 20 "$GATE" --upstream "$FIX/responses_host_time.sse" \
    --slave-file "$D83/mint.slave" --log "$D83/mint.jsonl" --turns 1 \
    > /dev/null 2> "$D83/mint.err"
r83m=$?
[ "$r83m" -eq 1 ] || { tail -3 "$D83/mint.err" >&2; fail "phase 83: a crafted verdict-LESS exec row exited rc=$r83m (want 1) — the loader MINTED an execution this seat never performed"; }
grep -q "claims exec=host but its verdict is (absent)" "$D83/mint.err" \
    || { tail -3 "$D83/mint.err" >&2; fail "phase 83: the refusal does not name the missing verdict"; }
grep -q "REFUSES TO START" "$D83/mint.err" \
    || fail "phase 83: the refusal is not loud"
[ ! -s "$D83/mint.slave" ] \
    || fail "phase 83: the slave path was published BEFORE the refusal — the mint was not refused at startup"
# the DENIED + exec shape is still refused by the SAME check (the message now
# renders the verdict it found instead of hard-coding "denied").
python3 - "$D83/denexec.jsonl" <<'PY'
import json, sys
row = {"ts": "2026-01-01T00:00:00Z", "session": None, "run": None, "turn": 1,
       "call_id": "call_S1FIX_DENEXEC", "true_name": "host_time", "args": "{}",
       "pending": False, "outcome": "a clock", "exec": "host",
       "verdict": "denied", "author": "denylist",
       "refusal_name": "denied-by-denylist", "reason": "r",
       "denial_text": "(denied by host policy: r)"}
open(sys.argv[1], "w").write(json.dumps(row) + "\n")
PY
rm -f "$D83/denexec.slave"
timeout 20 "$GATE" --upstream "$FIX/responses_host_time.sse" \
    --slave-file "$D83/denexec.slave" --log "$D83/denexec.jsonl" --turns 1 \
    > /dev/null 2> "$D83/denexec.err"
r83d=$?
[ "$r83d" -eq 1 ] || { tail -3 "$D83/denexec.err" >&2; fail "phase 83: a DENIED row claiming exec=host exited rc=$r83d (want 1) — the pair the seat can never write was not refused"; }
grep -q "claims exec=host but its verdict is denied" "$D83/denexec.err" \
    || { tail -3 "$D83/denexec.err" >&2; fail "phase 83: the denied+exec refusal does not name the verdict it found"; }
# THE TRUST BOUNDARY IS STATED WHERE IT IS MET: the --log usage must name the
# exec map, not only the pre-S1 fields (the residual is the same one, on new
# surface).
timeout 10 "$GATE" --nonsense > /dev/null 2> "$D83/usage.err"
grep -q "S1 exec map" "$D83/usage.err" \
    || { tail -5 "$D83/usage.err" >&2; fail "phase 83: the --log usage states the trust boundary only for the pre-S1 fields — a carried exec row's outcome is TRUSTED TEXT and the residual must be named where it is met"; }
echo "   OK mint refused: a verdict-less exec row (and a denied+exec row) refuse at startup before the slave path, and the usage names the exec map's trust residual"

echo "== phase 84: S1-fix (C) the FAIL-CLOSED UNARMED property — marker absent, row shape, sentinel crosses"
# COVERAGE (the review's finding C): every S1 arm above runs ARMED, so nothing
# asserted the `if (!policy_armed()) return;` gate in host_dispatch — a
# regression deleting that line would execute host_time with NO author in the
# record and pass every other arm.  The behaviour is CORRECT today (probed);
# this arm is the missing witness, and it fails in exactly that direction: an
# unarmed proxy that executes writes the marker, an exec row, and a host result
# on the wire.
s1_run "$GATE" unarmed "$FIX/responses_host_time.sse"
[ "$S1_GUEST_RC" -eq 0 ] || { sed -n '1,10p' "$S1_ERR" >&2; fail "phase 84: the guest run rc=$S1_GUEST_RC"; }
[ "$S1_RC" -eq 0 ] || fail "phase 84: the unarmed proxy exited rc=$S1_RC"
grep -q "guest dispatched $S1TOOL" "$S1_MARKER" 2>/dev/null \
    || fail "phase 84: the guest never dispatched the call — the unarmed arm is not the scenario"
grep -q "host-execute call_id=" "$S1_ERR" \
    && fail "phase 84: an UNARMED proxy EXECUTED a host call — there is no policy, so no author exists to record, and the fail-closed gate in host_dispatch is gone"
n=$(pyq "$S1_LOG" "len([r for r in rows if r.get('call_id')=='$S1CALL' and 'verdict' not in r and not r.get('exec')])")
[ "$n" -eq 1 ] || { grep -F "$S1CALL" "$S1_LOG" >&2; fail "phase 84: the unarmed row is not the P2 shape (no verdict field, no exec) for $S1CALL"; }
n=$(pyq "$S1_LOG" "len([r for r in rows if r.get('exec')])")
[ "$n" -eq 0 ] || fail "phase 84: an unarmed run wrote an exec field — it claims the host ran a call with no policy armed"
n=$(s1_out_n "$S1_DUMP" "o == '(tool call failed)'")
[ "$n" -ge 1 ] || { cat "$S1_DUMP" >&2; fail "phase 84: the guest's sentinel did not cross — an unarmed proxy must not substitute anything"; }
n=$(s1_out_n "$S1_DUMP" "'(host_time:' in o")
[ "$n" -eq 0 ] || fail "phase 84: a host RESULT crossed under an unarmed proxy"
echo "   OK unarmed: no host-execute marker, no verdict/exec field, the guest's sentinel crosses unsubstituted — the fail-closed gate is witnessed, not assumed"

# ── S2: THE JUDGED ARGUMENTS + THE TOTALITY CHECK (host_cat) ───────────────
#
# host_cat(path) is the FIRST CLASSED TOOL: its `path` argument is judged by
# the operator's alias table (D3 denies a PROTECTED class; the TOTALITY CHECK
# refuses an UNCLASSED path by name), and the executor opens EXACTLY the
# canonical spelling the judge classed (the normaliser crux).  The failure
# DIRECTION is the plan's risk #1 made concrete: a host call silently
# permitted because its argument matched nothing.
S2TOOL="host_cat"
S2CALL="call_S2_CAT_0001"
S2_PROTECTED="/fx/disk/agent-config.dhall"    # the Agentconfig row (protected=yes)
S2_UNCLASSED="/etc/definitely-not-classified" # matches NO alias row

# s2_policydir <dir> <tsv-file> — a COPY of the pinned policy dir with the
# alias table REPLACED and re-pinned (a valid pinned release of the SAME
# artifact, with operator-authored rows).  Never the shared dir.
s2_policydir() {
    local d="$1" tsv="$2"
    cp -r "$OPS_DIR" "$d"
    cp "$tsv" "$d/ops-aliases.tsv"
    ops_repin "$d"
}

# s2_run <gate> <tag> <pdir> <path> [extra...] — one whole guest loop through a
# bounded proxy over a host_cat fixture (path = the classed argument), with a
# FRESH FX_AGENT_DATA dir and a fresh stub per probe.  Exports S2_RC,
# S2_GUEST_RC, S2_DIR, S2_ERR, S2_LOG, S2_DUMP, S2_MARKER.  pdir="NONE" omits
# --ops-policy-dir ENTIRELY (the denylist-only/absent-seat configuration the
# S2-FIX 1 arm exists for), so --deny is the only policy in the run.
s2_run() {
    local gate="$1" tag="$2" pdir="$3" path="$4"
    shift 4
    local d="$TMP/s2-$tag"
    local opsargs=()
    [ "$pdir" = "NONE" ] || opsargs=(--ops-policy-dir "$pdir")
    mkdir -p "$d/data" "$d/cfg"
    make_refuse_stub "$d/stub.py" "$d/marker"
    cat > "$d/cfg/config.dhall" <<DHALL
{ agents =
  [ { name = "fx"
    , agent_type = "agent"
    , mcp_servers = [ { command = "$d/stub.py", args = [] : List Text } ]
    }
  ]
}
DHALL
    ops_stream "$d/fixture.sse" "$S2TOOL" "$path" "$S2CALL"
    "$gate" --upstream "$d/fixture.sse" --slave-file "$d/slave" \
        --log "$d/log.jsonl" --dump-requests "$d/dump.jsonl" \
        "${opsargs[@]}" --deny fx_write "$@" --turns 2 2> "$d/proxy.err" &
    local p=$!
    PROXIES="$PROXIES $p"
    wait_for_slave "$d/slave" "$p" "$d/proxy.err"
    local dev
    dev=$(cat "$d/slave")
    FX_CHARDEV="$dev" FX_AGENT_CONFIG_DIR="$d/cfg" \
    FX_AGENT_DATA="$d/data" HOME="$d" \
        timeout 120 "$BIN" -p "s2 probe" --agent fx --max-turns 2 --output text \
        > "$d/guest.out" 2>&1
    S2_GUEST_RC=$?
    wait_for_proxy_exit "$p" "$d/proxy.err"
    wait "$p"
    S2_RC=$?
    S2_DIR="$d"; S2_ERR="$d/proxy.err"; S2_LOG="$d/log.jsonl"
    S2_DUMP="$d/dump.jsonl"; S2_MARKER="$d/marker"; S2_DATA="$d/data"
}

# s2_out_n <dump> <predicate over `o`> — count host_cat outputs in the dumped
# (model-facing) frames for S2CALL whose output matches the predicate.
s2_out_n() {
    python3 - "$1" "$2" "$S2CALL" <<'PY'
import json, sys
dump, pred, cid = sys.argv[1], sys.argv[2], sys.argv[3]
n = 0
for line in open(dump):
    line = line.strip()
    if not line:
        continue
    f = json.loads(line)
    for it in f.get("input", []):
        if it.get("type") == "function_call_output" and it.get("call_id") == cid:
            o = it.get("output") or ""
            if eval(pred):
                n += 1
print(n)
PY
}

echo "== phase 85: S2 host_cat a PROTECTED path is DENIED by D3 — nothing executes"
# /fx/disk/agent-config.dhall is the Agentconfig row (protected=yes), so D3
# fires (hosttool + protected class).  The denial is the ordinary ops denial
# (fx_host_denied on the wire, nothing executes), attributed to rule D3.
s2_run "$GATE" protected "$OPS_DIR" "$S2_PROTECTED"
[ "$S2_GUEST_RC" -eq 0 ] || { sed -n '1,10p' "$S2_ERR" >&2; fail "phase 85: the guest run rc=$S2_GUEST_RC"; }
[ "$S2_RC" -eq 0 ] || fail "phase 85: the proxy exited rc=$S2_RC"
grep -q "host-execute call_id=" "$S2_ERR" \
    && fail "phase 85: the host EXECUTED a protected host_cat — D3 did not deny it"
grep -q "guest dispatched fx_host_denied" "$S2_MARKER" 2>/dev/null \
    || fail "phase 85: the guest did not receive the reserved name — the D3 denial did not take the rewrite path"
n=$(pyq "$S2_LOG" "len([r for r in rows if r.get('call_id')=='$S2CALL' and r.get('verdict')=='denied' and r.get('author')=='ops' and r.get('refusal_name')=='denied-by-ops' and 'rule D3' in (r.get('reason') or '') and not r.get('exec')])")
[ "$n" -eq 1 ] || { grep -F "$S2CALL" "$S2_LOG" >&2; fail "phase 85: no row carries verdict=denied author=ops refusal_name=denied-by-ops with rule D3 named and no exec"; }
n=$(s2_out_n "$S2_DUMP" "o.startswith('(denied by host policy:')")
[ "$n" -ge 1 ] || { cat "$S2_DUMP" >&2; fail "phase 85: the D3 denial text did not reach the model"; }
echo "   OK protected: D3 denies (author=ops, refusal_name=denied-by-ops, rule D3 named), nothing executes, the denial reaches the model"

echo "== phase 86: S2 host_cat an UNCLASSED path is REFUSED BY NAME — nothing executes"
# THE TOTALITY CHECK: a path that matches NO alias row has an unknown class,
# so the host REFUSES IT BY NAME (unclassed-arg) — the operator does not have
# to enumerate what is forbidden; anything unclassified is not permitted.
s2_run "$GATE" unclassed "$OPS_DIR" "$S2_UNCLASSED"
[ "$S2_GUEST_RC" -eq 0 ] || { sed -n '1,10p' "$S2_ERR" >&2; fail "phase 86: the guest run rc=$S2_GUEST_RC"; }
[ "$S2_RC" -eq 0 ] || fail "phase 86: the proxy exited rc=$S2_RC"
grep -q "host-execute call_id=" "$S2_ERR" \
    && fail "phase 86: the host EXECUTED an unclassed host_cat — the totality check did not refuse it"
n=$(pyq "$S2_LOG" "len([r for r in rows if r.get('call_id')=='$S2CALL' and r.get('verdict')=='denied' and r.get('author')=='ops' and r.get('refusal_name')=='unclassed-arg' and not r.get('exec')])")
[ "$n" -eq 1 ] || { grep -F "$S2CALL" "$S2_LOG" >&2; fail "phase 86: no row carries verdict=denied author=ops refusal_name=unclassed-arg with no exec"; }
n=$(s2_out_n "$S2_DUMP" "'unclassed-arg' in o")
[ "$n" -ge 1 ] || { cat "$S2_DUMP" >&2; fail "phase 86: the unclassed-arg refusal did not reach the model"; }
n=$(s2_out_n "$S2_DUMP" "'(host_cat:' in o")
[ "$n" -eq 0 ] || fail "phase 86: a host result crossed for a REFUSED path"
echo "   OK unclassed: refused by name (refusal_name=unclassed-arg), nothing executes, the refusal is the call's result"

echo "== phase 87: S2 MUTATION BLIND FH_MUTANT_OPS_NO_CLASS — a classed-out path EXECUTES"
# The class resolution AND the totality check compiled out: the protected path
# (which D3 would deny) and the unclassed path (which the totality check would
# refuse) BOTH reach the executor.  The dispatch marker is the witness.
s2_run "$GATEOPSNOCLASS" noclass-prot "$OPS_DIR" "$S2_PROTECTED"
[ "$S2_GUEST_RC" -eq 0 ] || { sed -n '1,10p' "$S2_ERR" >&2; fail "phase 87: the blind's guest run rc=$S2_GUEST_RC"; }
[ "$S2_RC" -eq 0 ] || fail "phase 87: the blind exited rc=$S2_RC"
grep -q "host-execute call_id=" "$S2_ERR" \
    || fail "phase 87: the NO_CLASS blind did NOT execute the protected path — the arm is vacuous"
n=$(pyq "$S2_LOG" "len([r for r in rows if r.get('call_id')=='$S2CALL' and r.get('exec')=='host'])")
[ "$n" -ge 1 ] || fail "phase 87: the blind's log carries no exec=host row for the protected path"
s2_run "$GATEOPSNOCLASS" noclass-unc "$OPS_DIR" "$S2_UNCLASSED"
[ "$S2_GUEST_RC" -eq 0 ] || { sed -n '1,10p' "$S2_ERR" >&2; fail "phase 87: the blind's guest run (unclassed) rc=$S2_GUEST_RC"; }
[ "$S2_RC" -eq 0 ] || fail "phase 87: the blind (unclassed) exited rc=$S2_RC"
grep -q "host-execute call_id=" "$S2_ERR" \
    || fail "phase 87: the NO_CLASS blind did NOT execute the unclassed path — the plan's risk #1 is not reproduced"
echo "   OK no-class blind: with class resolution + totality compiled out, the PROTECTED path AND the UNCLASSED path both EXECUTE (dispatch marker) — the real build refuses both"

echo "== phase 88: S2 FH_MUTANT_OPS_NO_CANON gates HOST paths too — a ../-spelling reaches the executor in the mutant, is refused in the real build"
# A COPY of the policy dir whose alias table maps a PROTECTED exact file and a
# NON-protected subtree whose base is a prefix of the ../-spelling.  The REAL
# build canonicalizes the spelling to the protected path and D3 denies it; the
# NO_CANON blind matches the RAW spelling against the non-protected subtree,
# ALLOWS it, and the executor (which still canonicalizes) opens the protected
# file — THE NORMALISER CRUX made concrete (classed as one thing, executed as
# another).
NCD="$TMP/s2-nocanon"
mkdir -p "$NCD/work/prot" "$NCD/work/data"
printf 'PROTECTED-SECRET-CONTENT' > "$NCD/work/prot/file.txt"
cat > "$NCD/aliases.tsv" <<TSV
# a temp operator table: one PROTECTED exact file, one NON-protected subtree.
Protfile	Configpath	yes	$NCD/work/prot/file.txt
Datasub	Datadir	no	$NCD/work/data/**
TSV
s2_policydir "$NCD/pdir" "$NCD/aliases.tsv"
SPELLING="$NCD/work/data/../prot/file.txt"
s2_run "$GATE" ncd-real "$NCD/pdir" "$SPELLING"
[ "$S2_GUEST_RC" -eq 0 ] || { sed -n '1,10p' "$S2_ERR" >&2; fail "phase 88: the real build's guest run rc=$S2_GUEST_RC"; }
[ "$S2_RC" -eq 0 ] || fail "phase 88: the real build exited rc=$S2_RC"
grep -q "host-execute call_id=" "$S2_ERR" \
    && fail "phase 88: the REAL build executed a ../-spelling of a protected path — the classifier did not canonicalize"
n=$(pyq "$S2_LOG" "len([r for r in rows if r.get('call_id')=='$S2CALL' and r.get('verdict')=='denied' and 'rule D3' in (r.get('reason') or '') and '$NCD/work/prot/file.txt' in (r.get('reason') or '')])")
[ "$n" -eq 1 ] || { grep -F "$S2CALL" "$S2_LOG" >&2; fail "phase 88: the real build did not deny the ../-spelling via D3 on the CANONICAL path"; }
s2_run "$GATEOPSNOCANON" ncd-mut "$NCD/pdir" "$SPELLING"
[ "$S2_GUEST_RC" -eq 0 ] || { sed -n '1,10p' "$S2_ERR" >&2; fail "phase 88: the blind's guest run rc=$S2_GUEST_RC"; }
[ "$S2_RC" -eq 0 ] || fail "phase 88: the blind exited rc=$S2_RC"
grep -q "host-execute call_id=" "$S2_ERR" \
    || fail "phase 88: the NO_CANON blind did NOT reach the executor — the ../-spelling was not misclassed"
n=$(s2_out_n "$S2_DUMP" "'PROTECTED-SECRET-CONTENT' in o")
[ "$n" -ge 1 ] || { cat "$S2_DUMP" >&2; fail "phase 88: the blind did not read the protected file's content — the executor did not open the canonical protected path"; }
echo "   OK normaliser: the ../-spelling is denied on the canonical path in the real build and REACHES THE EXECUTOR (reading the protected file) in the no-canonicalization blind — the classifier and the executor must agree"

echo "== phase 89: S2 host_cat an ALLOWED (classed, non-protected) path reads the file, bounded"
# The classed non-protected path: D3 does not fire (no protected class), the
# totality check passes (one row matched), and the executor reads the file —
# the content is substituted over the guest's sentinel, and the row's outcome
# is that content.  The outcome also names the CANONICAL spelling the executor
# opened (the normaliser proof on the allowed side).
AD="$TMP/s2-allowed"
mkdir -p "$AD/work"
printf 'ALLOWED-CONTENT-123' > "$AD/work/data.txt"
cat > "$AD/aliases.tsv" <<TSV
# a temp operator table: one NON-protected exact file.
Catfile	Datadir	no	$AD/work/data.txt
TSV
s2_policydir "$AD/pdir" "$AD/aliases.tsv"
s2_run "$GATE" allowed "$AD/pdir" "$AD/work/data.txt"
[ "$S2_GUEST_RC" -eq 0 ] || { sed -n '1,10p' "$S2_ERR" >&2; fail "phase 89: the guest run rc=$S2_GUEST_RC"; }
[ "$S2_RC" -eq 0 ] || fail "phase 89: the proxy exited rc=$S2_RC"
grep -q "host-execute call_id=" "$S2_ERR" \
    || fail "phase 89: the classed non-protected path was NOT executed"
grep -q "guest dispatched $S2TOOL" "$S2_MARKER" 2>/dev/null \
    || fail "phase 89: the allowed host_cat did not cross to the guest (the n_tool_calls>0 precondition)"
n=$(pyq "$S2_LOG" "len([r for r in rows if r.get('call_id')=='$S2CALL' and r.get('verdict')=='allowed' and r.get('exec')=='host' and 'ALLOWED-CONTENT-123' in (r.get('outcome') or '') and '$AD/work/data.txt' in (r.get('outcome') or '')])")
[ "$n" -eq 1 ] || { grep -F "$S2CALL" "$S2_LOG" >&2; fail "phase 89: no row is allowed+exec=host whose outcome is the file content on the canonical path"; }
n=$(s2_out_n "$S2_DUMP" "'ALLOWED-CONTENT-123' in o")
[ "$n" -ge 1 ] || { cat "$S2_DUMP" >&2; fail "phase 89: the file content did not reach the model"; }
n=$(s2_out_n "$S2_DUMP" "o == '(tool call failed)'")
[ "$n" -eq 0 ] || fail "phase 89: the guest's sentinel crossed for an executed host_cat — the substitution did not fire"
echo "   OK allowed: the classed non-protected path is read (content substituted over the sentinel), the row is allowed+exec=host with outcome = the content on the canonical path"

echo "== phase 90: S2 host_cat an OVER-CAP file is REFUSED, never truncated"
# The bound is honoured by REFUSAL, not silent truncation: a file longer than
# FH_HOST_CAT_MAX (256) is refused as the call's result, and no partial read
# crosses to the model.
OC="$TMP/s2-overcap"
mkdir -p "$OC/work"
python3 - "$OC/work/big.txt" <<'PY'
import sys
open(sys.argv[1], "wb").write(b"X" * (256 * 1024))
PY
cat > "$OC/aliases.tsv" <<TSV
Bigfile	Datadir	no	$OC/work/big.txt
TSV
s2_policydir "$OC/pdir" "$OC/aliases.tsv"
s2_run "$GATE" overcap "$OC/pdir" "$OC/work/big.txt"
[ "$S2_GUEST_RC" -eq 0 ] || { sed -n '1,10p' "$S2_ERR" >&2; fail "phase 90: the guest run rc=$S2_GUEST_RC"; }
[ "$S2_RC" -eq 0 ] || fail "phase 90: the proxy exited rc=$S2_RC"
grep -q "host-execute call_id=" "$S2_ERR" \
    || fail "phase 90: the over-cap file was not executed (the executor must RUN and refuse)"
n=$(s2_out_n "$S2_DUMP" "'exceeds the' in o")
[ "$n" -ge 1 ] || { cat "$S2_DUMP" >&2; fail "phase 90: the over-cap refusal did not reach the model"; }
n=$(s2_out_n "$S2_DUMP" "len(o) > 400")
[ "$n" -eq 0 ] || fail "phase 90: a huge read crossed — the bound truncated instead of refusing"
echo "   OK over-cap: a file longer than the bound is REFUSED (the refusal names the bound), never read partially"

# ── S2-FIX: THE S2 REVIEW'S ONE BLOCKER AND FOUR SHOULD-FIXES ─────────────
#
# Each arm below asserts a property whose ABSENCE the S2 review REPRODUCED
# through the real built proxy, and (where a build can carry the pre-fix
# shape) requires a PRE-FIX CONTROL of the SAME source to exhibit it — so no
# arm can pass because its fixture was inert.

echo "== phase 91: S2-FIX 1 (BLOCKER) — a CLASSED host tool does NOT execute where no ops seat judged it"
# THE HOLE: with --deny (which arms policy_armed(), and so the dispatch
# consult) and NO live operator author, the totality check had NO SEAT: every
# path was classed nothing and executed.  The S2 review measured a PROTECTED
# file's content reaching the model with a row reading allowed+exec=host in
# this configuration, which is the gate's own phase-71 shape.
UB="$TMP/s2f-unarmed"
mkdir -p "$UB/work/prot" "$UB/work/data"
printf 'PROTECTED-SECRET-CONTENT' > "$UB/work/prot/file.txt"
cat > "$UB/aliases.tsv" <<TSV
Protfile	Configpath	yes	$UB/work/prot/file.txt
Datasub	Datadir	no	$UB/work/data/**
TSV
s2_policydir "$UB/pdir" "$UB/aliases.tsv"
# (a) THE DENYLIST-ONLY CONFIGURATION: --deny fx_write, no --ops-policy-dir.
s2_run "$GATE" unarmed-ops NONE "$UB/work/prot/file.txt"
[ "$S2_GUEST_RC" -eq 0 ] || { sed -n '1,10p' "$S2_ERR" >&2; fail "phase 91: the guest run rc=$S2_GUEST_RC"; }
[ "$S2_RC" -eq 0 ] || fail "phase 91: the proxy exited rc=$S2_RC"
grep -q "host-execute call_id=" "$S2_ERR" \
    && fail "phase 91: the denylist-only seat EXECUTED a classed host call — the totality check vanished with the seat"
grep -qF "REFUSED at this seat (refusal_name=unarmed-ops)" "$S2_ERR" \
    || { sed -n '1,12p' "$S2_ERR" >&2; fail "phase 91: the no-policy startup line does not say a classed host call is refused here"; }
# THE AUTHOR IS THE ABSENCE, NOT THE OPERATOR: no ops author ran at this
# seat, so a row saying author=ops would claim an author that did not run
# (the honesty rule the log writer states for every other denial).  The row
# names `unarmed` and refusal_name=unarmed-ops.
n=$(pyq "$S2_LOG" "len([r for r in rows if r.get('call_id')=='$S2CALL' and r.get('verdict')=='denied' and r.get('author')=='unarmed' and r.get('refusal_name')=='unarmed-ops' and not r.get('exec')])")
[ "$n" -eq 1 ] || { grep -F "$S2CALL" "$S2_LOG" >&2; fail "phase 91: no row carries verdict=denied author=unarmed refusal_name=unarmed-ops with no exec"; }
n=$(s2_out_n "$S2_DUMP" "'unarmed-ops' in o")
[ "$n" -ge 1 ] || { cat "$S2_DUMP" >&2; fail "phase 91: the unarmed-ops refusal did not reach the model"; }
n=$(s2_out_n "$S2_DUMP" "'PROTECTED-SECRET-CONTENT' in o")
[ "$n" -eq 0 ] || fail "phase 91: the PROTECTED content reached the model from a seat with no operator author"
echo "   OK denylist-only: the classed host call is REFUSED BY NAME (unarmed-ops), nothing executes, the protected content never crosses"
# (b) THE OTHER NAMED CONFIGURATION — the LOADED-BUT-INERT seat (phase 44's
# D2-only artifact): OPS.present is 0 here too, so it is the SAME hole and the
# SAME refusal, and an arm that only covered (a) would miss it.
s2_run "$GATE" unarmed-inert "$TMP/p6-inert" "$UB/work/prot/file.txt"
[ "$S2_GUEST_RC" -eq 0 ] || { sed -n '1,10p' "$S2_ERR" >&2; fail "phase 91: the inert-seat guest run rc=$S2_GUEST_RC"; }
[ "$S2_RC" -eq 0 ] || fail "phase 91: the inert-seat proxy exited rc=$S2_RC"
grep -q "host-execute call_id=" "$S2_ERR" \
    && fail "phase 91: the LOADED-BUT-INERT seat executed a classed host call"
n=$(pyq "$S2_LOG" "len([r for r in rows if r.get('call_id')=='$S2CALL' and r.get('author')=='unarmed' and r.get('refusal_name')=='unarmed-ops' and not r.get('exec')])")
[ "$n" -eq 1 ] || fail "phase 91: the loaded-but-inert seat did not refuse with unarmed-ops"
echo "   OK loaded-but-inert: the same refusal with the seat LOADED and no rule live — the hole was not the absent flag alone"
# (c) THE ASYMMETRY — the PRE-FIX CONTROL (FH_MUTANT_NO_OPS_SEAT compiles the
# whole seat out, which is the state the blocker left every call in) EXECUTES
# the same call and the protected content CROSSES.  So (a)'s refusal is the
# gate's doing, not the fixture's.
s2_run "$GATENOOPS" unarmed-noops NONE "$UB/work/prot/file.txt"
[ "$S2_GUEST_RC" -eq 0 ] || { sed -n '1,10p' "$S2_ERR" >&2; fail "phase 91: the control's guest run rc=$S2_GUEST_RC"; }
[ "$S2_RC" -eq 0 ] || fail "phase 91: the control exited rc=$S2_RC"
grep -q "host-execute call_id=" "$S2_ERR" \
    || fail "phase 91: the PRE-FIX control did NOT execute the classed call — the arm is vacuous"
n=$(pyq "$S2_LOG" "len([r for r in rows if r.get('call_id')=='$S2CALL' and r.get('exec')=='host'])")
[ "$n" -ge 1 ] || fail "phase 91: the control's log carries no exec=host row"
n=$(s2_out_n "$S2_DUMP" "'PROTECTED-SECRET-CONTENT' in o")
[ "$n" -ge 1 ] || { cat "$S2_DUMP" >&2; fail "phase 91: the control did not hand the PROTECTED content to the model — the blocker's measured shape is not reproduced"; }
echo "   OK asymmetry: with the seat compiled out the SAME call EXECUTES and the protected content reaches the model — the refusal is the seat's"

echo "== phase 92: S2-FIX 2 — the class governs the SPELLING, the OPEN follows the kernel (symlink REFUSED)"
# A data-classed SYMLINK to a PROTECTED file: the judge classes the spelling
# (data subtree, not protected) and allows it; the kernel then resolves the
# link.  The S2 review measured the PROTECTED content returned both ways.  The
# fix opens with O_NOFOLLOW and refuses anything non-regular by name.
LK="$TMP/s2f-link"
mkdir -p "$LK/work/prot" "$LK/work/data"
printf 'PROTECTED-SECRET-CONTENT' > "$LK/work/prot/file.txt"
ln -s "$LK/work/prot/file.txt" "$LK/work/data/link.txt"
cat > "$LK/aliases.tsv" <<TSV
Protfile	Configpath	yes	$LK/work/prot/file.txt
Datasub	Datadir	no	$LK/work/data/**
TSV
s2_policydir "$LK/pdir" "$LK/aliases.tsv"
s2_run "$GATE" symlink "$LK/pdir" "$LK/work/data/link.txt"
[ "$S2_GUEST_RC" -eq 0 ] || { sed -n '1,10p' "$S2_ERR" >&2; fail "phase 92: the guest run rc=$S2_GUEST_RC"; }
[ "$S2_RC" -eq 0 ] || fail "phase 92: the proxy exited rc=$S2_RC"
grep -q "host-execute call_id=" "$S2_ERR" \
    || fail "phase 92: the classed symlink was not even EXECUTED (the arm must reach the executor to test it)"
n=$(pyq "$S2_LOG" "len([r for r in rows if r.get('call_id')=='$S2CALL' and 'not a plain file' in (r.get('outcome') or '') and r.get('exec')=='host'])")
[ "$n" -eq 1 ] || { grep -F "$S2CALL" "$S2_LOG" >&2; fail "phase 92: the executor did not REFUSE the symlink by name (not a plain file)"; }
n=$(s2_out_n "$S2_DUMP" "'not a plain file' in o")
[ "$n" -ge 1 ] || { cat "$S2_DUMP" >&2; fail "phase 92: the not-a-plain-file refusal did not reach the model"; }
n=$(s2_out_n "$S2_DUMP" "'PROTECTED-SECRET-CONTENT' in o")
[ "$n" -eq 0 ] || fail "phase 92: the PROTECTED content crossed through a data-classed symlink — the kernel resolved a spelling the judge classed"
echo "   OK symlink: the classed link is refused BY NAME (not a plain file); the protected target is never read"
# THE PRE-FIX CONTROL: the same source with the open hardening compiled out
# reads the PROTECTED content through the same link.
s2_run "$GATENOPLAINFILE" symlink-blind "$LK/pdir" "$LK/work/data/link.txt"
[ "$S2_GUEST_RC" -eq 0 ] || { sed -n '1,10p' "$S2_ERR" >&2; fail "phase 92: the blind's guest run rc=$S2_GUEST_RC"; }
[ "$S2_RC" -eq 0 ] || fail "phase 92: the blind exited rc=$S2_RC"
n=$(s2_out_n "$S2_DUMP" "'PROTECTED-SECRET-CONTENT' in o")
[ "$n" -ge 1 ] || { cat "$S2_DUMP" >&2; fail "phase 92: the PRE-FIX control did not read the protected content through the symlink — the arm is vacuous"; }
echo "   OK asymmetry: with O_NOFOLLOW/the type check compiled out the SAME link reads the PROTECTED content — the refusal is the executor's"

echo "== phase 92b: S2-FIX 2 — THE STATED RESIDUAL, PINNED: a HARDLINK is a regular file at a classed name"
# A hardlink cannot be refused by SPELLING: the classed name IS a regular file
# (the same inode as the protected one), so O_NOFOLLOW and the type check have
# nothing to refuse.  The operator's data-class grant therefore means "I trust
# what these NAMES resolve to", and directory-level trust is transitive over
# hardlinks.  This arm exists so the residual is MACHINE-VISIBLE instead of a
# comment a future reader trusts: it pins the CURRENT, wider behaviour, and it
# FAILS the day someone actually closes it (openat2/RESOLVE_* or an inode-level
# protected set) — with this arm to update, which is the point.  Nothing here
# is an approval of the reach.
ln "$LK/work/prot/file.txt" "$LK/work/data/hard.txt"
s2_run "$GATE" hardlink "$LK/pdir" "$LK/work/data/hard.txt"
[ "$S2_GUEST_RC" -eq 0 ] || { sed -n '1,10p' "$S2_ERR" >&2; fail "phase 92b: the guest run rc=$S2_GUEST_RC"; }
[ "$S2_RC" -eq 0 ] || fail "phase 92b: the proxy exited rc=$S2_RC"
n=$(s2_out_n "$S2_DUMP" "'PROTECTED-SECRET-CONTENT' in o")
[ "$n" -ge 1 ] || { cat "$S2_DUMP" >&2; fail "phase 92b: the hardlink residual is GONE (the protected content did not cross) — that is an improvement, so update this arm and the executor's residual note instead of deleting them"; }
n=$(pyq "$S2_LOG" "len([r for r in rows if r.get('call_id')=='$S2CALL' and r.get('verdict')=='allowed' and r.get('exec')=='host'])")
[ "$n" -eq 1 ] || fail "phase 92b: the hardlink arm is not the scenario (no allowed+exec=host row)"
echo "   OK residual PINNED: a data-classed HARDLINK still reads the protected inode (unfixable by spelling; stated in the executor) — the arm fails if it is ever closed"

echo "== phase 93: S2-FIX 3 — a FIFO is REFUSED PROMPTLY (it used to HANG the whole proxy)"
# MEASURED by the S2 review: guest rc=124, the proxy had to be SIGTERMed, no
# result and no refusal anywhere — an unbounded BLOCK in a single-lane proxy
# with no deadline around the executor.  O_NONBLOCK makes the open return;
# the S_ISREG check on the OPENED fd is what makes it a REFUSAL rather than an
# empty read.  This arm's bound is structural: a regression to blocking fails
# on wait_for_proxy_exit's own 40 s bound (and the guest's 120 s timeout), so
# the arm cannot hang either.
FF="$TMP/s2f-fifo"
mkdir -p "$FF/work/data"
mkfifo "$FF/work/data/pipe"
cat > "$FF/aliases.tsv" <<TSV
Datasub	Datadir	no	$FF/work/data/**
TSV
s2_policydir "$FF/pdir" "$FF/aliases.tsv"
s2_run "$GATE" fifo "$FF/pdir" "$FF/work/data/pipe"
[ "$S2_GUEST_RC" -eq 0 ] || { sed -n '1,10p' "$S2_ERR" >&2; fail "phase 93: the guest run rc=$S2_GUEST_RC (124 = the FIFO hung the lane)"; }
[ "$S2_RC" -eq 0 ] || fail "phase 93: the proxy exited rc=$S2_RC"
n=$(pyq "$S2_LOG" "len([r for r in rows if r.get('call_id')=='$S2CALL' and 'not a plain file' in (r.get('outcome') or '') and r.get('exec')=='host'])")
[ "$n" -eq 1 ] || { grep -F "$S2CALL" "$S2_LOG" >&2; fail "phase 93: the FIFO was not refused by name — the executor must not read it"; }
n=$(s2_out_n "$S2_DUMP" "'not a plain file' in o")
[ "$n" -ge 1 ] || { cat "$S2_DUMP" >&2; fail "phase 93: the FIFO refusal did not reach the model"; }
echo "   OK fifo: the classed FIFO is refused BY NAME and the run COMPLETES — the lane is not blocked, and the refusal (not an empty read) is the answer"

echo "== phase 94: S2-FIX 5 — NUL content is REFUSED BY NAME, never silently truncated"
# The result used to be rendered with %s: "HELLO\0SECRET-TAIL" reached the
# model as "HELLO" with NO marker — "refuse, never truncate" violated for
# every binary file.
NB="$TMP/s2f-nul"
mkdir -p "$NB/work/data"
printf 'HELLO\0SECRET-TAIL' > "$NB/work/data/bin.dat"
cat > "$NB/aliases.tsv" <<TSV
Datasub	Datadir	no	$NB/work/data/**
TSV
s2_policydir "$NB/pdir" "$NB/aliases.tsv"
s2_run "$GATE" nul "$NB/pdir" "$NB/work/data/bin.dat"
[ "$S2_GUEST_RC" -eq 0 ] || { sed -n '1,10p' "$S2_ERR" >&2; fail "phase 94: the guest run rc=$S2_GUEST_RC"; }
[ "$S2_RC" -eq 0 ] || fail "phase 94: the proxy exited rc=$S2_RC"
n=$(pyq "$S2_LOG" "len([r for r in rows if r.get('call_id')=='$S2CALL' and 'contains NUL' in (r.get('outcome') or '')])")
[ "$n" -eq 1 ] || { grep -F "$S2CALL" "$S2_LOG" >&2; fail "phase 94: no row carries the NUL refusal"; }
n=$(s2_out_n "$S2_DUMP" "'contains NUL' in o")
[ "$n" -ge 1 ] || { cat "$S2_DUMP" >&2; fail "phase 94: the NUL refusal did not reach the model"; }
n=$(s2_out_n "$S2_DUMP" "'SECRET-TAIL' in o")
[ "$n" -eq 0 ] || fail "phase 94: the bytes after the NUL crossed (or the file was truncated silently)"
n=$(s2_out_n "$S2_DUMP" "o.endswith(': HELLO)')")
[ "$n" -eq 0 ] || fail "phase 94: the pre-fix shape (content cut at the first NUL with no marker) crossed"
echo "   OK NUL: a file holding NUL bytes is refused BY NAME (contains NUL); no byte after the first NUL is silently dropped or delivered"

echo "== phase 95: S2-FIX 4 — the JUDGE reads the registry's arg_key (and startup refuses an entry that declares none)"
# (a) host_time declares NO classed argument (arg_key NULL): a path argument
# riding along is NOT the dimension this tool is judged on, so it is neither
# classed nor denied.  The pre-fix judge extracted the literal "path" for
# EVERY host tool and denied it — the observable half of the two-keys hazard
# that would leave S3's `fetch` url unjudged.
S2TOOL_SAVE="$S2TOOL"
S2TOOL="host_time"
s2_run "$GATE" timekey "$UB/pdir" "$UB/work/prot/file.txt"
S2TOOL="$S2TOOL_SAVE"
[ "$S2_GUEST_RC" -eq 0 ] || { sed -n '1,10p' "$S2_ERR" >&2; fail "phase 95: the guest run rc=$S2_GUEST_RC"; }
[ "$S2_RC" -eq 0 ] || fail "phase 95: the proxy exited rc=$S2_RC"
grep -q "host-execute call_id=" "$S2_ERR" \
    || fail "phase 95: host_time (which declares no classed argument) was not executed — the judge judged a key the registry does not name"
n=$(pyq "$S2_LOG" "len([r for r in rows if r.get('call_id')=='$S2CALL' and r.get('verdict')=='allowed' and r.get('exec')=='host' and \"HOST's wall clock\" in (r.get('outcome') or '')])")
[ "$n" -eq 1 ] || { grep -F "$S2CALL" "$S2_LOG" >&2; fail "phase 95: no allowed+exec=host row carrying host_time's own result"; }
n=$(pyq "$S2_LOG" "len([r for r in rows if r.get('call_id')=='$S2CALL' and r.get('verdict')=='denied'])")
[ "$n" -eq 0 ] || fail "phase 95: host_time was DENIED for a path it does not declare — the judge is still using a literal key"
# (b) THE PRE-FIX CONTROL: the hardcoded "path" key denies the same call.
s2_run "$GATEOPSLITKEY" timekey-blind "$UB/pdir" "$UB/work/prot/file.txt" 
[ "$S2_GUEST_RC" -eq 0 ] || { sed -n '1,10p' "$S2_ERR" >&2; fail "phase 95: the blind's guest run rc=$S2_GUEST_RC"; }
[ "$S2_RC" -eq 0 ] || fail "phase 95: the blind exited rc=$S2_RC"
n=$(pyq "$S2_LOG" "len([r for r in rows if r.get('call_id')=='$S2CALL' and r.get('verdict')=='denied' and 'rule D3' in (r.get('reason') or '') and not r.get('exec')])")
[ "$n" -eq 1 ] || { grep -F "$S2CALL" "$S2_LOG" >&2; fail "phase 95: the hardcoded-key control did not deny host_time — the arm cannot see the difference"; }
echo "   OK arg_key: host_time (arg_key NULL) is ALLOWED with a path riding along, and DENIED by the hardcoded-key control — the registry's declaration decides"
# (c) THE STARTUP CONTRACT: a registry entry that declares a READ and NO
# classed key is S3's `fetch` shape (its url would be neither classed nor
# totality-checked).  The REAL table starts; the table plus that one entry —
# with the pin overridden so the PIN is not what refuses — must REFUSE TO
# START, naming the tool.
mkdir -p "$TMP/s2f-extra"
timeout 20 "$GATE" --upstream "$TMP/upstream2.sse" \
    --slave-file "$TMP/s2f-extra/slave-real" --log "$TMP/s2f-extra/log-real.jsonl" \
    --turns 1 2> "$TMP/s2f-extra/err-real" &
ER=$!
PROXIES="$PROXIES $ER"
wait_for_slave "$TMP/s2f-extra/slave-real" "$ER" "$TMP/s2f-extra/err-real"
kill "$ER" 2>/dev/null
wait "$ER" 2>/dev/null
timeout 20 "$GATEEXTRAUNCL" --upstream "$TMP/upstream2.sse" \
    --slave-file "$TMP/s2f-extra/slave-extra" --log "$TMP/s2f-extra/log-extra.jsonl" \
    --turns 1 2> "$TMP/s2f-extra/err-extra"
EXRC=$?
[ "$EXRC" -ne 0 ] || { sed -n '1,6p' "$TMP/s2f-extra/err-extra" >&2; fail "phase 95: a registry entry declaring a read and NO arg_key did not refuse at startup (rc=$EXRC)"; }
grep -qF "host_fetch" "$TMP/s2f-extra/err-extra" \
    || { sed -n '1,6p' "$TMP/s2f-extra/err-extra" >&2; fail "phase 95: the startup refusal does not name the offending tool"; }
grep -qF "NO classed argument key" "$TMP/s2f-extra/err-extra" \
    || fail "phase 95: the startup refusal does not name the contract it enforces"
[ -s "$TMP/s2f-extra/slave-extra" ] \
    && fail "phase 95: the refusing build published its slave path — the refusal was not BEFORE the lane was published"
echo "   OK startup contract: the real table STARTS, the table plus an entry with a read and no classed key REFUSES TO START naming it (before the slave path exists)"

echo "== phase 96: S2-FIX 6 — the PATH is bounded too, so the record and the wire agree"
# The content bound alone did NOT make "always fits FH_BOUND" true: the path is
# MODEL-CHOSEN and every result/refusal text embeds it — the S2 review measured
# a 700-character path producing 777 bytes on the wire while the record
# rendered 512 with a truncation marker.  The executor now refuses a path over
# FH_HOST_PATH_MAX BY NAME, with a LENGTH-ONLY message (echoing it would
# re-create the overrun), so nothing this executor returns can exceed the cap.
LG="$TMP/s2f-long"
mkdir -p "$LG/work/data"
LONGPATH="$LG/work/data/$(python3 -c 'print("a" * 700)')"
cat > "$LG/aliases.tsv" <<TSV
Datasub	Datadir	no	$LG/work/data/**
TSV
s2_policydir "$LG/pdir" "$LG/aliases.tsv"
s2_run "$GATE" longpath "$LG/pdir" "$LONGPATH"
[ "$S2_GUEST_RC" -eq 0 ] || { sed -n '1,10p' "$S2_ERR" >&2; fail "phase 96: the guest run rc=$S2_GUEST_RC"; }
[ "$S2_RC" -eq 0 ] || fail "phase 96: the proxy exited rc=$S2_RC"
n=$(pyq "$S2_LOG" "len([r for r in rows if r.get('call_id')=='$S2CALL' and 'path bound' in (r.get('outcome') or '') and r.get('exec')=='host'])")
[ "$n" -eq 1 ] || { grep -F "$S2CALL" "$S2_LOG" >&2; fail "phase 96: the executor did not refuse the over-long path by name"; }
n=$(s2_out_n "$S2_DUMP" "'path bound' in o")
[ "$n" -ge 1 ] || { cat "$S2_DUMP" >&2; fail "phase 96: the path-bound refusal did not reach the model"; }
n=$(s2_out_n "$S2_DUMP" "len(o) > 512")
[ "$n" -eq 0 ] || fail "phase 96: the model was handed MORE than the record's 512-byte outcome cap — the record and the wire disagree"
echo "   OK path bound: an over-long model-chosen path is REFUSED BY NAME with a length-only message; no result exceeds the record's cap"

# ── THE PASS ECHO, with the LIVE observation folded in (P10-fix 5) ────────
echo "PASS hostgate: the transparent proxy is stream-transparent (arm == control) and a mangling proxy is caught; the per-turn open/close mechanics hold through one proxy process; the one log JOINS every answered call by call_id and REPORTS every call it could not join; a join compiled out flips the pass by content; every model-controlled free-text field arrives MARKED while the join key renders verbatim; the DECODE GATE holds the channel invariant for a denied call (the true name never crosses) in the presence of interleaves, duplicate/never-opened dones, open-at-completed items and over-cap streams, with a pinned pre-fix control for each; the RESERVED NAME is a CHECKED property (it passes the guest's charset, collides with no verb of a catalog pinned by sha256 and cross-checked against the verbs server's own table, and the proxy REFUSES TO START on a collision — while the same source with the check compiled out starts and DISPATCHES the colliding name: the silent allow); and the JUSTIFICATION is required in the injected tools schema, judged on the argument accumulator the guest actually dispatches (a done-args-only judge is pinned and caught), denied BY NAME through the existing substitution on the outbound leg, and REPORTED BY A DENIAL-RATE INSTRUMENT whose own compiled-out mutant leaves the dead-agent shape invisible; and THE OPERATOR IS A REAL AUTHOR AT THIS SEAT (P6: the pinned ops policy, its PINS check, its alias table with the TWO-FORM grammar re-run here, and its per-call fact injection with the path canonicalized before matching) with the D1/D2 split NAMED in the startup line — D1 evaluated here, D2 and the compiled-in FLOOR enforced IN-GUEST ONLY because this seat can see neither — the D2 bound ASSERTED in both directions, the ALLOWED row carrying its own seat-scoped allow_scope qualifier (so a durable record cannot read as a permission the seat never grants) with the LOADED-BUT-INERT branch pinned by its own D2-only arm, and the seat's three failure directions each pinned against a control of the SAME source (fail-open when the seat is compiled out, over-deny when it binds the floor it cannot see, silent allow when it matches the raw path); and THE CLAIM AUTHOR AT THIS SEAT (P7) pins the file that COMPUTES every verdict (a swapped always-derives eval_calls.py is REFUSED at startup, while the same source with the evaluator exempt from the pin arms and lets the forbidden call CROSS and EXECUTE), BOUNDS the per-call evaluator (a hung one becomes a RECORDED refusal with its row written, while the same source with no deadline HANGS and writes NOTHING — the dead-agent instrument's blind spot), and refuses a folded verb-SYMBOL mapped by TWO runtime verbs at both check sites (--check-verbs and the seat's loader), so no shared symbol can let one contention justify two runtime verbs; and the ONE LOG SURVIVES A KILL/RESTART (the load is a gate: a corrupt log refuses LOUDLY and is left untouched) with its second role as the JOIN STATE rebuilt from it — a pre-restart denial is restored and substituted on the frame the model sees — while the SAME source with the load compiled out WIPES the record and leaves the denial un-restored, the replay is IDEMPOTENT (same bytes twice, and load->flush reproduces the carried lines exactly), and a REAL RESUMED GUEST RUN gets the true name and the reason back on the outbound leg; and the FIVE SHOULD-FIXES THE P8 REVIEW FOUND ARE CLOSED, each against its own PRE-FIX CONTROL of the SAME source: a crafted-but-valid DENIED row can no longer drive the outbound leg unbounded (the loader applies the writer's bound at LOAD, so a 1 MB denial_text is restored as 512 MARKED bytes, while the control emits the reviewer's 1,048,576 and a call_id longer than the wire could carry is refused); the seat writes ONE ROW PER call_id (a re-serve is a repeat, not a second call — no phantom UNRESOLVED at any exit, phase 59's own log holding 1 row for its one guest-side call — the control inflating it and reporting the phantom), with the LOADER matching the writer by REFUSING a duplicate row; the LOAD is LINEAR rather than quadratic (100,000 rows in well under a 20 s bound where the pre-fix binary measured 89.7 s) and the over-cap refusal names a way out the gate RUNS — the DENIED-row compaction, whose rebuilt map still holds every denial; --log is REFUSED AT THE DOOR unless it is a regular file this seat owns (a FIFO that hung the pre-fix shape silently under a bounded control, a device node a flush would have renamed over, a symlink that would have split the record, a directory, all loud before anything is served or written); and a CARRIED row keeps the reading it was written with (its own allow_scope, byte-for-byte, where the control REWORDS it to claim a seat that judged nothing), while the turn field is validated as a whole non-negative number and the CRLF normalization is announced instead of silent; and the LIVE LANE'S LIVENESS SIGNALLING is closed (P10-fix), so the availability half of 'never a silent green' is enforced too: a REACHABLE-BUT-BROKEN response — no header block at all, an LF-only or non-HTTP status line, a Content-Length the socket does not honour, a chunked body with no well-formed zero chunk, or a body past the DOCUMENTED 32 MiB cap — is a LOUD NAMED failure (rc=1) where the pre-fix shape ended rc=0 with the bytes (or the whole header block) served to a guest that reads EOF as a FINISH, while a clean close-delimited 200 still passes; the HTTP HEADER BLOCK is never served as the body (the raw stream the guest reads begins with the BODY's own bytes, captured from the device); a credential embedded in the endpoint URL is never printed (userinfo refused by name and shown as <redacted>@, a query shown as ?<redacted>, and a CR/LF in the URL or the key refused before it could be sent); and the live arm's own observation rides in this echo, so an arm whose model made no call cannot read as an arm that proved something. $LIVE_STATUS; a HOST-TOOL call is an ORDINARY function_call (the SAME judge, the SAME denial path) and only the ALLOWED path dispatches it to the compiled-in host registry, whose result reaches the model through the EXISTING outbound substitution keyed on call_id (the pinned pre-S1 proxy crosses the SENTINEL instead); a host tool that collides with a guest verb is REFUSED at startup; and the executor compiled out is caught on the wire as SILENT DEGRADATION (S1 does NOT yet exercise argument judgement — host_time takes no arguments); the exec map is rebuilt across a restart and one call_id is executed at most ONCE; and an executed host call whose substitution never fires is REPORTED as an unresolved-substitution row; and a POLICY FLIP ACROSS A RESUME cannot break the record or lie to the model (S1-fix): a row refreshed to DENIED drops its execution reading and the exec-map key, so the seat still LOADS what its own two runs wrote, a carried DENIED verdict BINDS THE EXECUTOR rather than only the row, a crafted verdict-less exec row is REFUSED at startup, and ONE UNARMED arm witnesses the fail-closed gate instead of assuming it; and S2 THE JUDGED ARGUMENTS + THE TOTALITY CHECK: host_cat(path) is a BOUNDED host-file read (over-cap is REFUSED, never truncated), its path is judged by the operator's alias table through the hosttool(W) bridge (D3 denies a PROTECTED class while every guest-verb arm stays byte-identical), an UNCLASSED path is REFUSED BY NAME (unclassed-arg) with nothing executed, and the two mutation blinds flip exactly their arms — FH_MUTANT_OPS_NO_CLASS (the plan's risk #1 made concrete: the protected AND unclassed paths EXECUTE) and FH_MUTANT_OPS_NO_CANON now gating HOST paths (a ../-spelling reaches the executor and reads the protected file in the mutant, is denied on the canonical path in the real build) — proving the ONE normaliser (fh_canon_abs) is shared by the classifying and executing sides; S2-FIX: the totality check NO LONGER vanishes with the seat — a classed host call under a denylist-only OR loaded-but-inert seat is REFUSED BY NAME (unarmed-ops, where the seat-compiled-out control EXECUTES it and hands the model a protected file), the executor opens O_NOFOLLOW|O_NONBLOCK and refuses anything non-regular BY NAME (a data-classed symlink reads the protected target in the no-plainfile control; a FIFO no longer hangs the lane), NUL content is refused instead of silently cut, the judge extracts the registry's arg_key (the hardcoded-key control denies host_time where the real build allows it, and a table entry that reads with no classed key REFUSES TO START), and the model-chosen path is bounded so no result exceeds the record's cap"
