#!/usr/bin/env bash
# tests/test_outcome.sh — THE OBSERVATION-LOOP ORACLE (handoff-fx-harness-observe).
#
# THE RULE UNDER TEST (src/llm2/outcome.h):
#   "if the generation I am running in is not the one I activated, my activation
#    failed — do not repeat it", made precise against the store's own .bootlog:
#     A failed in the bootlog        -> ACTIVATION_FAILED (report, do not re-run)
#     A ok + done on record          -> ALREADY_DONE (it took; a later activation
#                                       moved on and the TASK completed)
#     A ok, NO done on record        -> SUPERSEDED (it booted, but nothing on
#                                       record says the TASK finished: report
#                                       honestly, do not claim a completion)
#     CURRENT == A                   -> RUN (it took), or ALREADY_DONE if done
#     A never judged + done          -> ALREADY_DONE (complete wins)
#     A never judged, no done        -> UNRESOLVED (report, do not re-run)
#     no activation, done            -> ALREADY_DONE
#     nothing recorded               -> RUN (the ordinary first boot)
#
# EVERY STOP IS PERMANENT UNTIL THE RECORD CHANGES, so the report must NAME the
# escape (the attempts.jsonl lines, or an operator --reconsider) — asserted in
# phases 2, 4 and 4b.
#
# THE FAILURE MODES THIS ORACLE PINS (each phase's comment names what it would
# let through, and each was shown FAILING against the pre-fix tree):
#   * a run the TURN LIMIT stopped must not record `done` (phase 0) and a run
#     that FINISHED must (phase 0b — the asymmetry);
#   * "it booted" is not "the task is complete" (phase 3b);
#   * an UNTERMINATED last line must not parse as a record (phase 4c — a torn
#     version token that matched a real bootlog line used to decide
#     ALREADY_DONE from a corrupt record);
#   * an unaccounted activation + a later COMPLETED run IS resolvable (phase 4d);
#   * the prompt axis is load-bearing and its DRIFT is LOUD (phase 5b);
#   * a CR/LF in the model-supplied config cannot forge a record line (phase 5c);
#   * a --resume must not re-record the seed's own activation (phase 5d);
#   * the record survives its worst-case field sizes (phase 5e — a 255-char
#     session plus a 511-char config, which silently lost the record at 768).
#
# WHAT IS REAL HERE, and what is planted:
#   REAL      the harness binary, the REAL tool server (build/fx-verbs-server) as
#             the agent's mcp_servers[0], the recorded SSE stream (no model, no
#             network), the DURABLE RECORD it writes under VIBE_RUNTIME_DIR, and
#             the fact that a refused task dispatches NOTHING (asserted by the
#             absence of a new session dir and by an unchanged record file).
#   PLANTED   the store's two outcome files (<store>/.db/snapshots/CURRENT and
#             <store>/.bootlog), which in a guest fx-init writes — this test is
#             the RULE's oracle; the guest-side ratchet itself is
#             tests/qemu-agent-observe.sh, which boots real machines.
#
# FIREABILITY (the asymmetry, phase 7): the same state that makes this binary
# refuse is handed to a binary built with -DFX_HARNESS_NO_OBSERVE — the pre-fix
# artifact, identical except that it never reads its own record back.  It must
# RUN and re-activate where the real binary refuses, so phase 2's "nothing was
# dispatched" assertion is a real assertion and not a tautology.
#
# Env: KEEP_TMP=1 keeps the scratch dir.  No network, no sleeps, no qemu.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN="$ROOT/build/fx-agent"
BLIND="$ROOT/build/fx-agent-blind"
VS="$ROOT/build/fx-verbs-server"
FIX="${VIBE_FIXTURE_DIR:-/var/lib/workspace/vibe-runtime/tests/fixtures}"

fail() { echo "FAIL outcome: $*" >&2; exit 1; }
note() { echo "   $*"; }

[ -x "$BIN" ] || fail "phase 0: $BIN missing — run make first"
[ -f "$FIX/responses_simple.sse" ] || fail "phase 0: fixture $FIX/responses_simple.sse missing"
[ -f "$ROOT/tools/fx-verbs-server.c" ] || fail "phase 0: tools/fx-verbs-server.c missing"

TMP=$(mktemp -d)
cleanup() { [ "${KEEP_TMP:-0}" = 1 ] || rm -rf "$TMP"; }
trap cleanup EXIT
echo "== outcome oracle: tmp: $TMP"

# the REAL tool server (not a stub): the org's verb table is what the loop
# dispatches into, so the activation reply this test parses is the real one.
if [ ! -x "$VS" ]; then
    sh "$ROOT/tools/build.sh" > "$TMP/verbs-build.log" 2>&1 \
        || { tail -20 "$TMP/verbs-build.log" >&2; fail "phase 0: tools/build.sh failed"; }
fi
[ -x "$VS" ] || fail "phase 0: $VS missing after tools/build.sh"

PROMPT="activate the config I just wrote"
PROMPT_TWO="a different task, same agent"
MARKER="FXO-AGENT-RAN"

STUB="$TMP/root"                       # FX_VERB_ROOT for the tool server
STORE="$STUB/fx/disk/store"            # the store, seen from BOTH sides
mkdir -p "$STUB/bin" "$STORE" "$TMP/cfg" || fail "cannot lay out the scratch tree"
printf '#!/bin/sh\necho "stub fx-activate: $*"\necho "activated 1111111111111111111111111111111111111111111111111111111111111111 as version 8; buildfile /stub/Dhakefile.dhall"\nexit 0\n' \
    > "$STUB/bin/fx-activate"
chmod +x "$STUB/bin/fx-activate"

# the agent's runtime config: the harness's OWN tool server, rooted at the stub
cat > "$TMP/cfg/config.dhall" <<DHALL
{ agents =
  [ { name = "fx"
    , agent_type = "agent"
    , mcp_servers =
      [ { command = "$VS"
        , args = [] : List Text
        , env = Some { FX_VERB_ROOT = "$STUB" }
        }
      ]
    }
  ]
}
DHALL

# ── the recorded SSE streams: the model, canned ───────────────────────────
# dev.sse      — a text turn + ONE fx_activate call (the ordinary live path).
# dev-text.sse — a text turn with NO tool calls: the loop reaches its FINAL
#                answer, which is the ONLY end-state that may record `done`.
# dev-forge.sse— built in phase 5c: an fx_activate whose config argument carries
#                a NEWLINE plus a whole forged `<epoch> <task> done - - 0 -` line.
mk_sse() { # mk_sse OUT TEXT CALLS-JSON
python3 - "$1" "$2" "$3" <<'PYEOF' || fail "cannot build the fixture $1"
import json, sys
out, text, calls_json = sys.argv[1], sys.argv[2], sys.argv[3]
calls = json.loads(calls_json) if calls_json else []
def ev(name, obj):
    return "event: %s\ndata: %s\n\n" % (name, json.dumps(obj))
s = []
s.append(ev("response.created", {"type": "response.created",
                                 "response": {"id": "fxo", "status": "in_progress"}}))
s.append(ev("response.output_text.delta",
            {"type": "response.output_text.delta", "delta": text,
             "item_id": "m0", "output_index": 0}))
for i, (cid, name, args) in enumerate(calls):
    a = json.dumps(args)
    idx = i + 1
    s.append(ev("response.output_item.added",
                {"type": "response.output_item.added", "output_index": idx,
                 "item": {"type": "function_call", "id": "fc%d" % i, "status": "in_progress",
                          "call_id": cid, "name": name, "arguments": ""}}))
    s.append(ev("response.function_call_arguments.delta",
                {"type": "response.function_call_arguments.delta", "delta": a,
                 "item_id": "fc%d" % i, "output_index": idx}))
    s.append(ev("response.output_item.done",
                {"type": "response.output_item.done", "output_index": idx,
                 "item": {"type": "function_call", "id": "fc%d" % i, "status": "completed",
                          "call_id": cid, "name": name, "arguments": a}}))
s.append(ev("response.completed", {"type": "response.completed",
                                   "response": {"id": "fxo", "status": "completed"}}))
open(out, "w").write("".join(s))
PYEOF
}
ACT_CALL='/fx/disk/agent-config.dhall'
mk_sse "$TMP/dev.sse" "$MARKER" \
    "[[\"call_fxo_activate\", \"fx_activate\", {\"config\": \"$ACT_CALL\"}]]"
mk_sse "$TMP/dev-text.sse" "$MARKER" "[]"
grep -q fx_activate "$TMP/dev.sse" || fail "the fixture carries no fx_activate call"

# ── helpers ─────────────────────────────────────────────────────────────────
plant_store() { # plant_store CURRENT "bootlog line"...
    _cur=$1; shift
    rm -rf "$STORE"
    mkdir -p "$STORE/.db/snapshots" || fail "cannot create the store"
    printf '%s\n' "$_cur" > "$STORE/.db/snapshots/CURRENT"
    : > "$STORE/.bootlog"
    for _l in "$@"; do printf '%s\n' "$_l" >> "$STORE/.bootlog"; done
}
newdata() { rm -rf "$TMP/data"; mkdir -p "$TMP/data" || fail "cannot create the data dir"; }
record()  { printf '%s\n' "$*" >> "$TMP/data/attempts.jsonl"; }
# THE probe: run the harness with a specific chardev + prompt, report rc + stdout.
runx() { # runx BIN PROMPT CHARDEV [extra argv...]
    _bin=$1 _p=$2 _dev=$3; shift 3
    FX_CHARDEV="$_dev" VIBE_RUNTIME_CONFIG_DIR="$TMP/cfg" \
    VIBE_RUNTIME_DIR="$TMP/data" HOME="$TMP" \
        "$_bin" -p "$_p" --agent fx --max-turns 2 --output text "$@" 2> "$TMP/err"
}
run() { # run [binary] [extra argv...]
    _bin=$1; shift
    runx "$_bin" "$PROMPT" "$TMP/dev.sse" "$@"
}
nsessions() { ls -1 "$TMP/data/sessions" 2>/dev/null | grep -cv '^\.' || true; }
# EVERY STOP MUST NAME ITS WAY OUT: the record is settled only by a later
# COMPLETED run of the same task, so the report has to name the record file AND
# the operator flag — otherwise the task is wedged with no documented recovery.
assert_escape() { # assert_escape PHASE REPORT
    printf '%s\n' "$2" | grep -q "attempts.jsonl" \
        || { printf '%s\n' "$2" >&2; fail "$1: the report does not name the record file that wedges the task"; }
    printf '%s\n' "$2" | grep -q -- "--reconsider" \
        || { printf '%s\n' "$2" >&2; fail "$1: the report does not name the operator escape (--reconsider)"; }
}

# ── phase 0: NOTHING ON RECORD -> RUN, and the attempt IS recorded ──────────
# ALSO PINS (a) that the run's TASK<->AGENT BINDING is written, and (b) that a
# run the TURN LIMIT stopped records NO `done`: the recorded stream is replayed
# every turn, so the loop's last allowed turn still carries tool calls that are
# never dispatched (agent_loop.c's `t == max_turns - 1` break).  Recording `done`
# there permanently marks an UNFINISHED task complete — the next boot would say
# "TASK ALREADY COMPLETE" and refuse to continue work that never happened.
echo "== phase 0: no record -> the task runs, records its activation + binding, and NO done (turn-limited)"
newdata
plant_store 8 "8 in-progress 1700000000" "8 ok 1700000010"
out=$(run "$BIN" --store "$STORE"); rc=$?
[ "$rc" = 0 ] || { cat "$TMP/err" >&2; fail "phase 0: rc=$rc (want 0)"; }
[ "$out" = "$MARKER" ] || fail "phase 0: stdout '$out', want $MARKER"
REC="$TMP/data/attempts.jsonl"
[ -s "$REC" ] || fail "phase 0: no durable record at $REC"
grep -q " attempt " "$REC" || { cat "$REC"; fail "phase 0: no attempt line"; }
grep -q " result "  "$REC" || { cat "$REC"; fail "phase 0: no result line"; }
grep -Eq "^[0-9]+ [0-9a-f]{16} agent [^ ]+ [^ ]+ 0 fx\$" "$REC" \
    || { cat "$REC"; fail "phase 0: no task<->agent binding line (a prompt change cannot be detected without it)"; }
grep -q " done "    "$REC" \
    && { cat "$REC"; fail "phase 0: a TURN-LIMITED run recorded 'done' — the next boot would call this unfinished task COMPLETE"; }
grep -q "turn limit" "$TMP/err" \
    || { cat "$TMP/err" >&2; fail "phase 0: the run did not SAY it stopped on the turn limit"; }
grep -q " 8 /fx/disk/agent-config.dhall\$" "$REC" \
    || { cat "$REC"; fail "phase 0: the result line does not carry the generation the verb named (v8) + the config"; }
TASK=$(awk 'NR==1{print $2}' "$REC")
echo "$TASK" | grep -Eq '^[0-9a-f]{16}$' \
    || fail "phase 0: task id '$TASK' is not 16 hex"
[ "$(nsessions)" = 1 ] || fail "phase 0: expected exactly 1 session dir, got $(nsessions)"
note "record: $(tr '\n' '|' < "$REC")"
note "task id $TASK; stdout '$out'"

# ── phase 0b: THE ASYMMETRY FOR `done` — a run that FINISHES records it ─────
# Without this, phase 0's "no done" would also pass on a harness that never
# records `done` at all.  The SAME store and the SAME agent, with a recorded
# stream that ends on a text turn (no tool calls): the loop reaches its final
# answer, so the task IS complete and `done` MUST be recorded.
echo "== phase 0b: a run that reaches its FINAL answer DOES record done (the asymmetry)"
newdata
plant_store 8 "8 in-progress 1700000000" "8 ok 1700000010"
out=$(runx "$BIN" "$PROMPT" "$TMP/dev-text.sse" --store "$STORE"); rc=$?
[ "$rc" = 0 ] || { cat "$TMP/err" >&2; fail "phase 0b: rc=$rc (want 0)"; }
[ "$out" = "$MARKER" ] || fail "phase 0b: stdout '$out', want $MARKER"
grep -q " done " "$REC" \
    || { cat "$REC"; fail "phase 0b: a run that produced a FINAL answer (no tool calls) recorded no 'done'"; }
grep -q "turn limit" "$TMP/err" \
    && { cat "$TMP/err" >&2; fail "phase 0b: a run that FINISHED was reported as turn-limited"; }
note "a completed run records done: $(grep ' done ' "$REC")"

# ── phase 1: CURRENT == the generation I activated, task NOT done -> RUN ────
echo "== phase 1: current == activated and the task is unfinished -> RUN"
newdata
plant_store 8 "8 in-progress 1700000000"
record "1700000000 $TASK attempt - - 0 /fx/disk/agent-config.dhall"
record "1700000000 $TASK result - - 8 /fx/disk/agent-config.dhall"
out=$(run "$BIN" --store "$STORE"); rc=$?
[ "$rc" = 0 ] || { cat "$TMP/err" >&2; fail "phase 1: rc=$rc (want 0)"; }
[ "$out" = "$MARKER" ] || fail "phase 1: the task did not run (stdout '$out') — an activation that TOOK must not block it"
[ "$(nsessions)" = 1 ] || fail "phase 1: the task did not create a session"
note "the activation took (current v8 == activated v8): the task ran again, as it should"

# ── phase 2: the roll-forward -> ACTIVATION_FAILED, and NOTHING is dispatched ─
echo "== phase 2: my generation FAILED in the bootlog -> report, do NOT re-run"
newdata
plant_store 9 "8 in-progress 1700000000" "8 failed 1700000020" "9 in-progress 1700000030"
record "1700000000 $TASK attempt - - 0 /fx/disk/agent-config.dhall"
record "1700000000 $TASK result - - 8 /fx/disk/agent-config.dhall"
record "1700000025 $TASK done - - 0 -"
cp "$REC" "$TMP/rec-before"
out=$(run "$BIN" --store "$STORE"); rc=$?
[ "$rc" = 0 ] || { cat "$TMP/err" >&2; fail "phase 2: rc=$rc (want 0 — a refusal is not a service failure)"; }
echo "$out" | grep -q "THE ACTIVATION THIS HARNESS RECORDED FAILED" \
    || { echo "$out" >&2; fail "phase 2: no ACTIVATION_FAILED report on stdout"; }
echo "$out" | grep -q "NOT REPEATING IT" || fail "phase 2: the report does not say it is not repeating"
echo "$out" | grep -q "v8" || fail "phase 2: the report does not name the failed generation"
# THE WAY OUT MUST BE NAMED: a stop with no escape is a permanent, unexplained
# wedge (the record is only ever settled by a later COMPLETED run).
echo "$out" | grep -q "attempts.jsonl" \
    || { echo "$out" >&2; fail "phase 2: the report does not name the record that wedges the task"; }
echo "$out" | grep -q -- "--reconsider" \
    || { echo "$out" >&2; fail "phase 2: the report does not name the operator escape"; }
case "$out" in *"$MARKER"*) fail "phase 2: the loop RAN on a failed activation (marker present)";; esac
[ "$(nsessions)" = 0 ] \
    || fail "phase 2: a session dir was created — the task was started ($(nsessions))"
cmp -s "$REC" "$TMP/rec-before" \
    || { cat "$REC"; fail "phase 2: the record changed — it must be read, never consumed/rewritten"; }
note "refused with exit 0, no session, no dispatch, record untouched:"
printf '%s\n' "$out" | sed 's/^/      /'

# ── phase 3: it TOOK (ok in the bootlog) and a later activation moved on ─────
echo "== phase 3: my generation booted OK and the store moved on -> ALREADY_DONE"
newdata
plant_store 9 "8 in-progress 1700000000" "8 ok 1700000020" "9 in-progress 1700000030"
record "1700000000 $TASK attempt - - 0 /fx/disk/agent-config.dhall"
record "1700000000 $TASK result - - 8 /fx/disk/agent-config.dhall"
record "1700000025 $TASK done - - 0 -"
out=$(run "$BIN" --store "$STORE"); rc=$?
[ "$rc" = 0 ] || fail "phase 3: rc=$rc (want 0)"
echo "$out" | grep -q "TASK ALREADY COMPLETE" || { echo "$out" >&2; fail "phase 3: no ALREADY_DONE report"; }
case "$out" in *"$MARKER"*) fail "phase 3: a completed task was re-run";; esac
[ "$(nsessions)" = 0 ] || fail "phase 3: a session dir was created"
note "an activation that took is not repeated, and neither is a completed task"

# ── phase 3b: it TOOK, but nothing on record says the TASK finished ─────────
# "It booted" is not "the task is complete".  The store moved past my generation
# and its verdict is ok, but there is NO `done` marker for the task: a completion
# the record does not hold must not be claimed.  The STOP stays (repeating an
# activation that took is the blind re-apply the loop exists to stop), the REPORT
# changes.  BEFORE THIS PHASE the same state printed "TASK ALREADY COMPLETE" — a
# claim the record cannot support.
echo "== phase 3b: it booted ok but the TASK has no done marker -> SUPERSEDED, honestly reported"
newdata
plant_store 9 "8 in-progress 1700000000" "8 ok 1700000020" "9 in-progress 1700000030"
record "1700000000 $TASK attempt - - 0 /fx/disk/agent-config.dhall"
record "1700000000 $TASK result - - 8 /fx/disk/agent-config.dhall"
cp "$REC" "$TMP/rec-before3b"
out=$(run "$BIN" --store "$STORE"); rc=$?
[ "$rc" = 0 ] || fail "phase 3b: rc=$rc (want 0)"
echo "$out" | grep -q "TOOK AND WAS SUPERSEDED" \
    || { echo "$out" >&2; fail "phase 3b: the report does not say the activation TOOK and was superseded"; }
echo "$out" | grep -q "NOT RECORDED COMPLETE" \
    || { echo "$out" >&2; fail "phase 3b: the report does not say the task is NOT recorded complete"; }
echo "$out" | grep -q "NO \`done\` marker" \
    || { echo "$out" >&2; fail "phase 3b: the report does not name the missing done marker"; }
case "$out" in *"TASK ALREADY COMPLETE"*)
    fail "phase 3b: the report claims the task is COMPLETE while nothing on record says so";; esac
case "$out" in *"$MARKER"*) fail "phase 3b: the loop RAN (marker present) — the stop must not change";; esac
[ "$(nsessions)" = 0 ] || fail "phase 3b: a session dir was created"
cmp -s "$REC" "$TMP/rec-before3b" \
    || { cat "$REC"; fail "phase 3b: the record changed"; }
note "$(printf '%s\n' "$out" | sed -n '1,2p' | tr '\n' ' ')"

# ── phase 4: an activation the store never judged -> UNRESOLVED, do not repeat ─
echo "== phase 4: the generation I activated was never judged -> UNRESOLVED"
newdata
plant_store 9 "9 in-progress 1700000030"
record "1700000000 $TASK attempt - - 0 /fx/disk/agent-config.dhall"
record "1700000000 $TASK result - - 8 /fx/disk/agent-config.dhall"
out=$(run "$BIN" --store "$STORE"); rc=$?
[ "$rc" = 0 ] || fail "phase 4: rc=$rc (want 0)"
echo "$out" | grep -q "STORE CANNOT ACCOUNT FOR" || { echo "$out" >&2; fail "phase 4: no UNRESOLVED report"; }
case "$out" in *"$MARKER"*) fail "phase 4: the loop ran on an unresolved activation";; esac
[ "$(nsessions)" = 0 ] || fail "phase 4: a session dir was created"

# ── phase 4b: an attempt whose outcome was never flushed (died mid-call) ─────
echo "== phase 4b: an activation attempt with no recorded outcome -> UNRESOLVED"
newdata
plant_store 8 "8 in-progress 1700000000"
record "1700000000 $TASK attempt - - 0 /fx/disk/agent-config.dhall"
out=$(run "$BIN" --store "$STORE"); rc=$?
[ "$rc" = 0 ] || fail "phase 4b: rc=$rc (want 0)"
echo "$out" | grep -q "STORE CANNOT ACCOUNT FOR" || { echo "$out" >&2; fail "phase 4b: no UNRESOLVED report"; }
case "$out" in *"$MARKER"*) fail "phase 4b: the loop ran on a half-recorded activation";; esac
[ "$(nsessions)" = 0 ] || fail "phase 4b: a session dir was created"
assert_escape "phase 4b" "$out"

# ── phase 4c: a TORN last line must not parse as a record ──────────────────
# A crash (or ENOSPC) mid-write leaves a PREFIX of a record line.  A prefix that
# cuts INSIDE the version token still yields six parseable fields, so the loader
# used to ADOPT it: here the truncated "1" of an intended "12" matches a real
# `1 ok` bootlog line, and the verdict was ALREADY_DONE — a SILENT "the task is
# complete", decided from a CORRUPT record, which is the one thing fail-open must
# never do.  With the newline-termination rule the torn line is skipped, so the
# record has no result for the task: the conservative UNRESOLVED stop.
echo "== phase 4c: a torn (unterminated) last line is not a record -> UNRESOLVED, never a silent done"
newdata
plant_store 12 "1 ok 1700000020" "12 in-progress 1700000030"
record "1700000000 $TASK attempt - - 0 /fx/disk/agent-config.dhall"
printf '%s' "1700000000 $TASK result - - 1" >> "$REC"   # torn: no newline (intended v12)
[ "$(tail -c 1 "$REC" | od -An -c | tr -d ' \n')" != "\\n" ] \
    || fail "phase 4c: the probe did not write a torn line (the file ends with a newline)"
out=$(run "$BIN" --store "$STORE"); rc=$?
[ "$rc" = 0 ] || fail "phase 4c: rc=$rc (want 0)"
case "$out" in *"TASK ALREADY COMPLETE"*)
    fail "phase 4c: a CORRUPT (torn) record line was read as 'the task is complete'";; esac
echo "$out" | grep -q "STORE CANNOT ACCOUNT FOR" \
    || { echo "$out" >&2; fail "phase 4c: the torn line was adopted — want the conservative UNRESOLVED stop"; }
case "$out" in *"$MARKER"*) fail "phase 4c: the loop RAN on a torn record";; esac
[ "$(nsessions)" = 0 ] || fail "phase 4c: a session dir was created"
assert_escape "phase 4c" "$out"

# ── phase 4c-2: a torn tail must not DISTURB a complete record ─────────────
# The other direction of the same rule: a torn last line appended to a record that
# already carries a judged activation must not change the verdict.  The verdict
# must still come from the LAST COMPLETE line (A failed -> ACTIVATION_FAILED),
# never from the torn one (whose truncated version is looked up in the bootlog).
echo "== phase 4c-2: a torn tail on top of a complete record does not change the verdict"
newdata
plant_store 9 "8 in-progress 1700000000" "8 failed 1700000020" "9 in-progress 1700000030"
record "1700000000 $TASK attempt - - 0 /fx/disk/agent-config.dhall"
record "1700000000 $TASK result - - 8 /fx/disk/agent-config.dhall"
printf '%s' "1700000025 $TASK done - - 0" >> "$REC"      # torn: no newline (intended the last field)
out=$(run "$BIN" --store "$STORE"); rc=$?
[ "$rc" = 0 ] || fail "phase 4c-2: rc=$rc (want 0)"
echo "$out" | grep -q "THE ACTIVATION THIS HARNESS RECORDED FAILED" \
    || { echo "$out" >&2; fail "phase 4c-2: a torn tail changed the verdict — it must be computed from the last COMPLETE line"; }
case "$out" in *"$MARKER"*) fail "phase 4c-2: the loop RAN";; esac
[ "$(nsessions)" = 0 ] || fail "phase 4c-2: a session dir was created"

# ── phase 4d: an unaccounted activation + a LATER COMPLETED run IS resolvable ─
# The record cannot account for the activation (no generation was ever named),
# but a `done` marker is on record: the task HAS completed since.  That is the
# ONLY way the record can ever be settled (see `escape`), so it must settle it —
# before this phase the same state was UNRESOLVED FOREVER, i.e. a permanent wedge
# that no harness surface could clear.
echo "== phase 4d: an unaccounted activation followed by a COMPLETED run -> the completion settles it"
newdata
plant_store 8 "8 in-progress 1700000000" "8 ok 1700000010"
record "1700000000 $TASK attempt - - 0 /fx/disk/agent-config.dhall"
record "1700000010 $TASK result - - 0 /fx/disk/agent-config.dhall"
record "1700000090 $TASK done - - 0 -"
out=$(run "$BIN" --store "$STORE"); rc=$?
[ "$rc" = 0 ] || fail "phase 4d: rc=$rc (want 0)"
echo "$out" | grep -q "TASK ALREADY COMPLETE" \
    || { echo "$out" >&2; fail "phase 4d: a completed run of the task did not settle the unaccounted activation"; }
echo "$out" | grep -q "cannot account for that activation" \
    || { echo "$out" >&2; fail "phase 4d: the report does not name the activation the record cannot account for"; }
case "$out" in *"$MARKER"*) fail "phase 4d: a completed task was re-run";; esac
[ "$(nsessions)" = 0 ] || fail "phase 4d: a session dir was created"
note "the wedge is resolvable by a completing run — the record is settled, not silent"

# ── phase 4e: --reconsider is the operator's documented way out ────────────
# The report names it, so it must EXIST and must be LOUD: an operator override
# that prints nothing is indistinguishable from the refusal it overrode.
echo "== phase 4e: --reconsider overrides a refusal (loudly) and runs the task"
newdata
plant_store 8 "8 in-progress 1700000000"
record "1700000000 $TASK attempt - - 0 /fx/disk/agent-config.dhall"
out=$(run "$BIN" --store "$STORE" --reconsider); rc=$?
[ "$rc" = 0 ] || { cat "$TMP/err" >&2; fail "phase 4e: rc=$rc (want 0) — --reconsider unknown/refused"; }
[ "$out" = "$MARKER" ] || { echo "$out" >&2; fail "phase 4e: --reconsider did not run the task"; }
grep -q "RECONSIDERING" "$TMP/err" \
    || { cat "$TMP/err" >&2; fail "phase 4e: the override was SILENT"; }
[ "$(nsessions)" = 1 ] || fail "phase 4e: the task was not started"
note "$(grep RECONSIDERING "$TMP/err")"

# ── phase 5: a completed task that never activated -> do not re-run ─────────
echo "== phase 5: a completed task with no activation -> ALREADY_DONE"
newdata
plant_store 8 "8 in-progress 1700000000" "8 ok 1700000010"
record "1700000010 $TASK done - - 0 -"
out=$(run "$BIN" --store "$STORE"); rc=$?
[ "$rc" = 0 ] || fail "phase 5: rc=$rc (want 0)"
echo "$out" | grep -q "TASK ALREADY COMPLETE" || { echo "$out" >&2; fail "phase 5: no ALREADY_DONE report"; }
case "$out" in *"$MARKER"*) fail "phase 5: the completed task was re-run";; esac
[ "$(nsessions)" = 0 ] || fail "phase 5: a session dir was created"

# ── phase 5b: the task identity is the (agent, prompt) PAIR, and a drifted ──
#    identity is LOUD ─────────────────────────────────────────────────────────
# The task id is FNV-1a-64(agent, prompt), so it is stable only while the prompt
# is.  A prompt with anything boot-varying in it makes EVERY boot a new task: the
# record never matches, every boot re-runs, and the loop is SILENTLY INERT.  That
# is why the record now carries a task<->agent BINDING and the boot compares it:
# a different task id for an agent already on record must be reported, not
# silently re-run.  The check has to be fireable BOTH ways: the SECOND run of the
# new prompt (now bound) must be quiet.
echo "== phase 5b: a DIFFERENT prompt is a different task -> it still runs, and the drift is SAID OUT LOUD"
newdata
plant_store 8 "8 in-progress 1700000000"
record "1699999999 $TASK agent oldsession 000000000000 0 fx"
record "1700000000 $TASK attempt - - 0 /fx/disk/agent-config.dhall"
record "1700000000 $TASK result - - 8 /fx/disk/agent-config.dhall"
record "1700000025 $TASK done - - 0 -"
_out=$(runx "$BIN" "$PROMPT_TWO" "$TMP/dev.sse" --store "$STORE")
[ "$_out" = "$MARKER" ] || { cat "$TMP/err" >&2; fail "phase 5b: a different task was blocked (stdout '$_out')"; }
grep -q "TASK IDENTITY DRIFT" "$TMP/err" \
    || { cat "$TMP/err" >&2; fail "phase 5b: a DIFFERENT task id for an agent already on record was re-run SILENTLY (the loop is inert and nothing says so)"; }
grep -q "$TASK" "$TMP/err" || fail "phase 5b: the drift warning does not name the task already on record"
_other=$(awk '$3=="agent"{print $2}' "$REC" | sort -u | grep -v "^$TASK\$" | head -1)
echo "$_other" | grep -Eq '^[0-9a-f]{16}$' || fail "phase 5b: the second task got no binding line"
grep -q "$_other" "$TMP/err" || fail "phase 5b: the drift warning does not name the task this boot computed"
[ "$(awk '{print $2}' "$REC" | sort -u | grep -cv "^$TASK\$")" = 1 ] \
    || fail "phase 5b: the second task did not get its own record"
note "the record now names two distinct task ids, and the drift is reported:"
note "$(grep 'TASK IDENTITY DRIFT' "$TMP/err" | cut -c1-160)"
# FIREABILITY, the other direction: the new task is now BOUND, so a second boot
# of it must NOT warn (a sensor that always fires is not a sensor).
_out=$(runx "$BIN" "$PROMPT_TWO" "$TMP/dev.sse" --store "$STORE")
[ "$_out" = "$MARKER" ] || fail "phase 5b: the second boot of the new task did not run"
grep -q "TASK IDENTITY DRIFT" "$TMP/err" \
    && { cat "$TMP/err" >&2; fail "phase 5b: the drift warning fired for an ALREADY-BOUND task (it would fire forever)"; }
note "the same prompt on the next boot is bound — no drift warning"

# ── phase 5c: a CR/LF in the model-supplied config cannot forge a record ───
# The config argument comes from the MODEL, and the attempt line is durable
# BEFORE the verb is dispatched (so even an activation that kills the machine is
# recorded) — which means a newline in it used to write ARBITRARY record lines,
# e.g. a `done` line for this very task: the harness marking an unfinished task
# complete on the model's say-so, even if fx_activate then rejects the path.
echo "== phase 5c: a CR/LF in the model-supplied config cannot forge a record line"
newdata
plant_store 8 "8 in-progress 1700000000"
mk_sse "$TMP/dev-forge.sse" "$MARKER" \
    "[[\"call_forge\", \"fx_activate\", {\"config\": \"/fx/disk/agent-config.dhall\\n1700000000 $TASK done - - 0 -\"}]]"
grep -q 'fx_activate' "$TMP/dev-forge.sse" || fail "phase 5c: cannot build the forge fixture"
_out=$(runx "$BIN" "$PROMPT" "$TMP/dev-forge.sse" --store "$STORE"); rc=$?
[ "$rc" = 0 ] || { cat "$TMP/err" >&2; fail "phase 5c: rc=$rc (want 0)"; }
[ -z "$(awk '$3=="done"' "$REC")" ] \
    || { cat "$REC"; fail "phase 5c: a NEWLINE in the config argument FORGED a 'done' RECORD (field 3 == done) — the model can mark its own task complete"; }
[ "$(awk '{print $2}' "$REC" | sort -u | grep -cv "^$TASK\$")" = 0 ] \
    || { cat "$REC"; fail "phase 5c: a forged record line names another task"; }
[ "$(wc -l < "$REC" | tr -d ' ')" = 3 ] \
    || { cat "$REC"; fail "phase 5c: the record has the wrong number of lines (binding+attempt+result=3) — a forged line got in"; }
note "the forged text stays INSIDE the config field, inert:"
note "$(grep ' attempt ' "$REC" | cut -c1-150)"

# ── phase 5d: --resume must not re-record the SEED's own activation ────────
# The loop re-notifies every resume seed, and the record hook is fired from that
# same notification.  A seed CAN be an activation (a run killed between the
# assistant message and the tool result is exactly what --resume is for), so
# re-recording it writes a DUPLICATE attempt line stamped with the RESUMED
# session/run: the record then claims the resumed run dispatched what the
# PRE-DEATH run actually dispatched, and the session named in a later report is
# the wrong one.
echo "== phase 5d: --resume does not re-record the seed's own activation (no duplicate lines)"
newdata
plant_store 8 "8 in-progress 1700000000" "8 ok 1700000010"
mkdir -p "$TMP/data/sessions/seedsess" || fail "phase 5d: cannot create the seed session"
python3 - "$TMP/data/sessions/seedsess/messages.jsonl" "$PROMPT" <<'PYEOF' || fail "phase 5d: cannot write the seed transcript"
import json, sys
out, prompt = sys.argv[1], sys.argv[2]
args = json.dumps({"config": "/fx/disk/seed-config.dhall"})
msgs = [
    {"role": "user", "content": prompt},
    {"role": "assistant", "content": "",
     "tool_calls": [{"id": "call_seed", "name": "fx_activate", "arguments": args}]},
    {"role": "tool", "tool_call_id": "call_seed",
     "content": "activated aaaa as version 4; buildfile /stub/Dhakefile.dhall"},
]
open(out, "w").write("".join(json.dumps(m) + "\n" for m in msgs))
PYEOF
record "1699999999 $TASK agent seedsess 000000000000 0 fx"
record "1700000000 $TASK attempt seedsess 000000000000 0 /fx/disk/seed-config.dhall"
_out=$(run "$BIN" --resume seedsess --store "$STORE"); rc=$?
[ "$rc" = 0 ] || { cat "$TMP/err" >&2; fail "phase 5d: rc=$rc (want 0)"; }
[ "$_out" = "$MARKER" ] || { echo "$_out" >&2; fail "phase 5d: the resumed run did not reach the fixture"; }
[ "$(grep -c '/fx/disk/seed-config.dhall' "$REC" | tr -d ' ')" = 1 ] \
    || { cat "$REC"; fail "phase 5d: the SEED's activation was re-recorded — a duplicate attempt/result stamped with the RESUMED session"; }
grep -q " attempt seedsess " "$REC" \
    || { cat "$REC"; fail "phase 5d: the seed's ORIGINAL attempt line (with its own session) was lost"; }
grep -q " attempt .* /fx/disk/agent-config.dhall\$" "$REC" \
    || { cat "$REC"; fail "phase 5d: the appended-result path did not record THIS run's own activation (the seed skip must not disable recording)"; }
note "$(wc -l < "$REC" | tr -d ' ') record line(s); the seed's activation is on record exactly once"

# ── phase 5e: the record survives its WORST-CASE field sizes ───────────────
# The writer's line buffer was 768 bytes while its field caps sum to ~900 (a
# 255-char session — the NAME_MAX a session directory can have — plus a 511-char
# config): the record was silently DROPPED (the writer's snprintf refused, the
# caller warned once, and the next boot read "nothing on record" and RAN).  The
# probe drives the record API directly at those caps, so the assertion is about
# the SIZING, not about a lucky guest configuration.
echo "== phase 5e: the worst-case record (255-char session + 511-char config) round-trips"
cat > "$TMP/probe.c" <<'CEOF'
/* The record's worst case, straight at the API: a session as long as NAME_MAX
 * allows and a config at FX_OUTCOME_PATH_CAP-1.  A record that does not survive
 * its own caps is a record the next boot cannot see (and then RUNs). */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include "outcome.h"

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    (void)mkdir(argv[1], 0755);
    char sess[256];                      /* a session id is a path component */
    memset(sess, 's', 255); sess[255] = '\0';
    char cfg[FX_OUTCOME_PATH_CAP];
    memset(cfg, 'c', FX_OUTCOME_PATH_CAP - 1); cfg[FX_OUTCOME_PATH_CAP - 1] = '\0';
    const char *task = "0123456789abcdef";
    if (fx_outcome_record(argv[1], task, "attempt", sess, "000000000000", 0, cfg) != 0) {
        fprintf(stderr, "probe: the writer REFUSED the worst-case line (buffer too small for its own caps)\n");
        return 1;
    }
    FxOutcome o;
    if (fx_outcome_record_load(argv[1], task, &o) != 0) { fprintf(stderr, "probe: load failed\n"); return 1; }
    if (!o.has_attempt) {
        fprintf(stderr, "probe: the worst-case record was LOST — the next boot would read nothing and RUN\n");
        return 1;
    }
    if (strcmp(o.session, sess) != 0) {
        fprintf(stderr, "probe: the session did not round-trip (%zu of %zu chars)\n",
                strlen(o.session), strlen(sess));
        return 1;
    }
    if (strcmp(o.config, cfg) != 0) {
        fprintf(stderr, "probe: the config did not round-trip (%zu of %zu chars)\n",
                strlen(o.config), strlen(cfg));
        return 1;
    }
    printf("probe: worst-case record round-trips (session %zu, config %zu)\n",
           strlen(o.session), strlen(o.config));
    return 0;
}
CEOF
cc -std=c11 -O2 -Wall -Wextra -I"$ROOT/src" -I"$ROOT/src/llm2" \
   -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE \
   -o "$TMP/probe" "$TMP/probe.c" "$ROOT/src/llm2/outcome.c" \
   || fail "phase 5e: cannot build the record-size probe"
rm -rf "$TMP/probe-data"
"$TMP/probe" "$TMP/probe-data" || fail "phase 5e: the record does not survive its own field caps"
note "$("$TMP/probe" "$TMP/probe-data.2" | sed 's/^/   /')"

# ── phase 6: the store is NEVER guessed ────────────────────────────────────
echo "== phase 6: a verdict that needs the store FAILS LOUDLY when it is absent"
newdata
plant_store 9 "8 in-progress 1700000000" "8 failed 1700000020"
record "1700000000 $TASK attempt - - 0 /fx/disk/agent-config.dhall"
record "1700000000 $TASK result - - 8 /fx/disk/agent-config.dhall"
run "$BIN" --store "$TMP/no-such-store" >/dev/null; rc=$?
[ "$rc" = 2 ] || fail "phase 6: explicit --store that does not exist -> rc=$rc (want 2)"
grep -q "the store is never guessed" "$TMP/err" || { cat "$TMP/err" >&2; fail "phase 6: no loud refusal for an absent --store"; }
_out=$(run "$BIN"); rc=$?
[ "$rc" = 2 ] || fail "phase 6: an unreadable DEFAULT store -> rc=$rc (want 2)"
grep -q "/fx/disk/store" "$TMP/err" \
    || { cat "$TMP/err" >&2; fail "phase 6: the failure does not NAME the store it could not read"; }
note "$(cat "$TMP/err")"

# ── phase 7: FIREABILITY — the pre-fix artifact RUNS where this one refuses ──
echo "== phase 7: asymmetry — the -DFX_HARNESS_NO_OBSERVE build (make blind) re-runs the failed task"
(cd "$ROOT" && make blind) > "$TMP/blind-build.log" 2>&1 \
    || { tail -20 "$TMP/blind-build.log" >&2; fail "phase 7: 'make blind' failed (the pre-fix artifact)"; }
[ -x "$BLIND" ] || fail "phase 7: $BLIND missing after 'make blind'"
# the SAME state phase 2 refused to run
out=$(run "$BLIND" --store "$STORE"); rc=$?
[ "$rc" = 0 ] || { cat "$TMP/err" >&2; fail "phase 7: the blind build rc=$rc"; }
[ "$out" = "$MARKER" ] \
    || { echo "$out" >&2; fail "phase 7: the blind build did NOT re-run the failed task — phase 2's refusal proves nothing"; }
[ "$(nsessions)" = 1 ] || fail "phase 7: the blind build created no session"
grep -c " attempt " "$REC" | grep -q '^2$' \
    || { cat "$REC"; fail "phase 7: the blind build's re-activation is not on the record"; }
note "ASYMETRY PROVEN: identical state, identical fixture — the blind build re-ran"
note "and re-activated the task (2 attempts on record); the real build refused it."

echo "PASS outcome: nothing-on-record RUNS and records the attempt; a run the TURN LIMIT"
echo "              stopped records NO done (and a run that FINISHED does); an activation that"
echo "              TOOK is not re-run, and a completion the record does not hold is never"
echo "              claimed; a FAILED one is reported and NOT repeated (exit 0, no dispatch,"
echo "              record untouched) with its way out NAMED; a torn last line cannot decide a"
echo "              verdict; an unaccounted activation is settled by a completing run and is"
echo "              escapable with --reconsider; a drifted task identity is said OUT LOUD; a"
echo "              newline in the config cannot forge a record line; a --resume does not"
echo "              re-record its seed; the worst-case record round-trips; the store is never"
echo "              guessed (loud exit 2); and the pre-fix artifact re-runs the very task this"
echo "              one refuses."
exit 0
