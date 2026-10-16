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
FIX="${FX_FIXTURE_DIR:-$ROOT/tests/fixtures}"
MARKER="FX-GUEST-LOOP-OK-8f31"
SENTINEL="hostgate-p1-probe"
# the call the tool fixture carries (the join key for every P2 assert)
CALLID="call_00_DgJfXOD0j0bvOV7jB0tl0124"
# the two calls the interleave/sequential fixtures carry (P3-fix)
CALL_A="call_A_0001"  # get_weather
CALL_B="call_B_0002"  # fx_write
# the policy fields RESERVED for P3/P5 — their presence in a P2 row is a
# claim wider than the evidence (no policy has run)
POLICY_FIELDS="verdict allowed author refusal_name reason denial_text"

fail() { echo "FAIL $*" >&2; exit 1; }

[ -x "$BIN" ] || fail "phase 0: $BIN missing — run make first"
[ -x "$GATE" ] || fail "phase 0: $GATE missing — run make first"
[ -x "$GATEMUT" ] || fail "phase 0: $GATEMUT missing — run make first"
[ -x "$GATEUNB" ] || fail "phase 0: $GATEUNB missing — run make first"
[ -x "$GATENRW" ] || fail "phase 0: $GATENRW missing — run make first"
[ -x "$GATEADD" ] || fail "phase 0: $GATEADD missing — run make first"
[ -x "$GATESI" ] || fail "phase 0: $GATESI missing — run make first"
[ -x "$GATENOS" ] || fail "phase 0: $GATENOS missing — run make first"
[ -f "$FIX/responses_simple.sse" ] || fail "phase 0: fixture $FIX/responses_simple.sse missing"
[ -f "$FIX/responses_tool.sse" ] || fail "phase 0: fixture $FIX/responses_tool.sse missing"
[ -f "$FIX/responses_interleaved.sse" ] || fail "phase 0: fixture $FIX/responses_interleaved.sse missing"
[ -f "$FIX/responses_sequential.sse" ] || fail "phase 0: fixture $FIX/responses_sequential.sse missing"

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
    n=$(pyq "$1" "len([1 for r in rows for k in ('verdict','allowed','author','refusal_name','reason','denial_text') if k in r])") \
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
# never a hang (the gate must always end).
wait_for_proxy_exit() {
    local i=0
    while kill -0 "$1" 2>/dev/null && [ "$i" -lt 100 ]; do # <= 10 s
        sleep 0.1
        i=$((i + 1))
    done
    if kill -0 "$1" 2>/dev/null; then
        tail -5 "$2" >&2 || true
        fail "the proxy (pid $1) did not exit within 10s — see log above"
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
deadline = time.time() + 15
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

echo "PASS hostgate: the transparent proxy is stream-transparent (arm == control), a mangling proxy is caught, the per-turn open/close mechanics hold through one proxy process, and the one log JOINS every answered call by call_id while REPORTING every call it could not join — the positive and negative directions both proven, a join compiled out flips the pass by content, and every model-controlled free-text field arrives MARKED (never silently truncated) while the join key renders verbatim — and (P3) a DENIED call's true name never crosses the chardev (not even as bytes), nothing executes (marker absent under the allow-all config), the denial reaches the model as the call's own result (restored name + denial text in the dumped outbound frame), the accepted direction still crosses VERBATIM and executes, the P2-era control and the added-event completeness mutant both DISPATCH and are caught by content"
