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
#   * a done that PREDATES a later attempt does NOT settle it — the loader's
#     done is position-aware (phase 4f, unit-asymmetried in 5g against PINNED
#     pre-fix sources, never a moving HEAD), and a done -> attempt -> RESULT
#     order is NOT a false RUN: the done returns to force once the attempt is
#     accounted, and re-suspends behind a further unaccounted one (phase 5g);
#   * the prompt axis is load-bearing and its DRIFT is LOUD (phase 5b);
#   * a CR/LF in the model-supplied config cannot forge a record line (phase 5c);
#   * a --resume must not re-record the seed's own activation (phase 5d);
#   * the record survives its worst-case field sizes (phase 5e — a 255-char
#     session plus a 511-char config, which silently lost the record at 768);
#   * a record appended after a TORN tail survives (phase 5g tailrepair —
#     O_APPEND used to merge the new record into the torn prefix);
#   * the four cells the ordering review found UNGATED are pinned (phase 5g):
#     the overlapping cell's ROW PRECEDENCE (ok ∧ C==A ∧ no done -> SUPERSEDED,
#     not RUN), done->attempt->result at C!=A (UNRESOLVED), the v0-result
#     reinstatement (ALREADY_DONE), and the DAMAGE RULE — a torn attempt line
#     whose result survived used to read RUN (the re-issuing direction,
#     asymmetried against PINNED 014ebb7); it now reads UNRESOLVED, and a done
#     in force stays ALREADY_DONE (the decision: positive evidence, not poisoned);
#   * fx_write's write surface is the HOST-DECLARED writable set: the record
#     path is refused (loudly, naming path and set) while the task config
#     still writes, the DOCUMENTED root-relative entry spelling grants it,
#     a '..' onto an allowed member still writes, and the PINNED pre-fix
#     servers show both holes (phase 8);
#   * the recovery journal's UNREADABLE state is its OWN state, distinct from
#     absent and from zero (phase 9g) — MEASURED, a directory where the journal
#     belongs used to read as "0 roll-forwards … the FIRST time", a measurement
#     that was never made;
#   * an unreadable BOOTLOG is FX_VERDICT_ERROR naming the path — never RUN,
#     which re-issues the activation (phase 11) — MEASURED, a directory (or a
#     mode-000 file) where .bootlog belongs, with CURRENT == the activated
#     generation, used to fall through to "no verdict line" and RUN; the same
#     phase pins the bootlog's own DAMAGE RULE (a torn tail NAMING the
#     activated generation refuses the ordinary re-run, scoped to the named
#     generation), the ABSENT bootlog as SILENCE (a store that predates
#     .bootlog — the journal's absent-is-a-state rule; the done-in-force cell
#     stays ALREADY_DONE under an unreadable bootlog too), and the record's
#     unreadable state (a directory at attempts.jsonl is not "no record"),
#     each with its readable control;
#   * A CUT REPORT IS LOUD (phase 10): report() emits an explicit truncation
#     marker naming the byte count and FX_OUTCOME_MSG_CAP, into the tail of the
#     buffer so the marker cannot itself be cut; the cap is DERIVED from the
#     format strings and MEASURED at exactly the field caps, and the asymmetry
#     is shown against the pinned pre-marker outcome.c (which cuts the same
#     report silently).
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
        , env = Some { FX_VERB_ROOT = "$STUB"
                     , FX_AGENT_WRITABLE = "/fx/disk/agent-config.dhall" }
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
# plant_journal plants <store>/.recovery, fx-init 4d6a8c2's journal (one data
# line "<epoch> <published> <from> <genhash>" per AUTOMATIC roll-forward, with
# the definition in the file's own '#' header — reproduced from the writer,
# init.zig recovery_line, NOT from a description of it).
plant_journal() { # plant_journal "data line"...  (no lines -> header only)
    : > "$STORE/.recovery"
    printf '# fx-init recovery journal. One DATA line per AUTOMATIC roll-forward:\n' >> "$STORE/.recovery"
    printf '# line: <epoch-s> <published-version> <from-failed-version> <content-genhash|->\n' >> "$STORE/.recovery"
    for _l in "$@"; do printf '%s\n' "$_l" >> "$STORE/.recovery"; done
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

# ── phase 1b: current == activated and the task IS done -> ALREADY_DONE ────
# The C==A branch's completion arm: the bootlog holds NO verdict line for A
# (the store never judged it), so the rule falls through to CURRENT == A with
# `done` on record.  Every STOP report must name its way out — the report is
# the operator's only channel, and this one used to carry no escape line.
echo "== phase 1b: current == activated, task done -> ALREADY_DONE, escape named"
newdata
plant_store 8
record "1700000000 $TASK attempt - - 0 /fx/disk/agent-config.dhall"
record "1700000000 $TASK result - - 8 /fx/disk/agent-config.dhall"
record "1700000025 $TASK done - - 0 -"
out=$(run "$BIN" --store "$STORE"); rc=$?
[ "$rc" = 0 ] || fail "phase 1b: rc=$rc (want 0)"
echo "$out" | grep -q "TASK ALREADY COMPLETE" || { echo "$out" >&2; fail "phase 1b: no ALREADY_DONE report"; }
case "$out" in *"$MARKER"*) fail "phase 1b: a completed task was re-run";; esac
[ "$(nsessions)" = 0 ] || fail "phase 1b: a session dir was created"
assert_escape "phase 1b" "$out"
note "C==A with done: ALREADY_DONE, and the escape is named"

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
assert_escape "phase 3" "$out"
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

# ── phase 4f: a done that PREDATES a later attempt does not settle it ──────
# The loader's done used to be STICKY and POSITION-BLIND: ANY done line for
# the task pre-empted ANY later unaccounted attempt, and the report claimed
# "a LATER run of this task COMPLETED" over a record where the done PREDATES
# the attempt — inverted.  A done may settle only the attempts that PRECEDE
# it.  Here the completed run (done, epoch ...010) is FOLLOWED by a new,
# never-accounted activation attempt (epoch ...020): the STOP stays (repeating
# an unaccounted activation is the blind re-apply this unit exists to stop —
# a false RUN is the guarded failure mode, a false stop is the SAFE error and
# is escapable), and the REPORT becomes the honest UNRESOLVED one.
echo "== phase 4f: done BEFORE a later unaccounted attempt -> UNRESOLVED, never ALREADY_DONE"
newdata
plant_store 8 "8 in-progress 1700000000" "8 ok 1700000010"
record "1700000010 $TASK done - - 0 -"
record "1700000020 $TASK attempt - - 0 /fx/disk/agent-config.dhall"
out=$(run "$BIN" --store "$STORE"); rc=$?
[ "$rc" = 0 ] || fail "phase 4f: rc=$rc (want 0)"
echo "$out" | grep -q "STORE CANNOT ACCOUNT FOR" \
    || { echo "$out" >&2; fail "phase 4f: no UNRESOLVED report for an attempt that POSTDATES the done"; }
case "$out" in *"TASK ALREADY COMPLETE"*)
    fail "phase 4f: a done line that PREDATES the attempt settled it — the loader's done is position-blind";; esac
case "$out" in *"$MARKER"*) fail "phase 4f: the loop ran";; esac
[ "$(nsessions)" = 0 ] || fail "phase 4f: a session dir was created"
assert_escape "phase 4f" "$out"
note "a done that predates the attempt no longer settles it: UNRESOLVED (still a stop, honestly reported)"

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
    if (fx_outcome_record_load(argv[1], task, &o, NULL, 0) != 0) { fprintf(stderr, "probe: load failed\n"); return 1; }
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

# ── phase 5g: UNIT ASYMMETRY at the record API — done order + torn tail ────
# Two invariants this oracle cannot observe through the binary's outside (the
# report WORDING is covered by 4f; the loader's ORDER semantics and the
# O_APPEND tail repair are not observable via any report), probed straight at
# fx_outcome_* — once against THIS tree and once against PINNED pre-fix
# sources, so every assertion below is shown to be able to FAIL:
#   done-first    : done line, THEN a later unaccounted attempt.  The loader
#                   must not let the earlier done settle the later attempt
#                   (fixed: UNRESOLVED; pre-fix: ALREADY_DONE — the bug).
#   attempt-first : the ORDINARY order (attempt, then done) must be UNCHANGED
#                   by the fix: ALREADY_DONE in both builds.
#   tailrepair    : a torn (unterminated) tail, then ONE well-formed record.
#                   O_APPEND used to MERGE the new record into the torn
#                   prefix — both lines lost, the next boot reads "nothing on
#                   record" and RUNS; the writer now closes a torn tail with
#                   a newline BEFORE appending (fixed: the record survives;
#                   pre-fix: lost).
#   done-first-   : done, then attempt, then that attempt's RESULT (vN), with
#     result        the store's CURRENT == vN.  648984f's position-aware
#                   loader cleared the done at the attempt and nothing put it
#                   back, so the C==A branch returned RUN — a FALSE RUN that
#                   re-issues an activation for a task the record says
#                   COMPLETED (reachable via --resume, which bypasses the
#                   start gate but still writes attempt/result lines).  A
#                   later attempt now clears the done ONLY while that attempt
#                   is UNACCOUNTED: the result puts the done back in force
#                   (fixed: ALREADY_DONE; 648984f: RUN — the bug, this round).
#   ok-ca         : THE OVERLAPPING CELL — A ok in the bootlog AND C == A AND
#                   no done.  The rows are a PRECEDENCE order, not disjoint
#                   patterns: the bootlog verdict on A is reached before the
#                   C == A comparison, so this cell is SUPERSEDED, not RUN.
#                   FAILS IF the branches are reordered (the C == A row would
#                   decide RUN) — nothing else pinned the precedence.
#   dar-cneqa     : done -> attempt -> result at C != A (the 5g probe planted
#                   CURRENT == A only).  The reinstated done must not leak a
#                   completion claim into the never-judged row: UNRESOLVED, a
#                   conservative stop.  FAILS IF the final row starts
#                   consulting `done` (ALREADY_DONE) or the reinstatement
#                   changes so the attempt reads unaccounted (RUN).
#   v0-reinstate  : a result naming NO generation (v0) still ACCOUNTS the
#                   attempt, so the suspended done returns to force:
#                   ALREADY_DONE, with no store needed.  FAILS IF the
#                   reinstatement grows a version check — the done would stay
#                   suspended and the verdict would become UNRESOLVED.
#   torn-attempt  : THE DAMAGE RULE (was todo.md §3's re-issuing hole): the
#     (+ -tail,     attempt line torn mid-step-token (ENOSPC), then the
#      +orphan-done) result write SUCCEEDS — the writer's tail repair closes
#                   the torn prefix as its own unparsable line and the result
#                   lands complete.  The attempt is unreadable, the result is
#                   an ORPHAN: fixed -> UNRESOLVED, NEVER RUN off a record
#                   that provably lost a line; the pinned pre-damage-rule
#                   source (014ebb7) shows RUN — the measured hole, both
#                   arms.  -tail is the torn attempt as the LAST line (no
#                   repair): same UNRESOLVED via the torn-line flag (its
#                   visible counterpart — a complete attempt with no result —
#                   is UNRESOLVED too).  orphan-done pins the DECISION half:
#                   a done in force is positive evidence and is NOT poisoned
#                   (ALREADY_DONE, before and after — wedging a completed
#                   task would buy no safety).
#
# THE PRE-FIX ARMS ARE PINNED REVISIONS, NEVER HEAD: this phase once read
# `git show HEAD:` — a MOVING ref that was the pre-fix source only while the
# fix was UNCOMMITTED; the moment 648984f landed, HEAD became the FIXED
# source, every asymmetry here went VACUOUS, and the gate turned red forever
# (the pre-fix loader no longer showed the bug).  Nothing in this gate may
# depend on the position of HEAD.  A shallow clone or rewritten history can
# legitimately lack a pin; that is a SKIP said OUT LOUD, never a silent
# vacuous pass.  And the control's DOMAIN is asserted: a pinned source that
# happens to EQUAL the working file would prove exactly as little as a moving
# one, so each extraction is diffed against the tree and a match SKIPS this arm
# LOUDLY (it does not fail the gate: the other arm pins the fixed behaviour
# unconditionally, so a reverted fix still turns the gate red rather than
# passing vacuously).
PIN_STICKY="648984f^"   # the sticky-done loader (the bug 648984f fixed)
PIN_FALSE="648984f"     # the loader whose done->attempt->result returned RUN
PRE86=""
MID86=""
git -C "$ROOT" cat-file -e "$PIN_STICKY^{commit}" 2>/dev/null \
    || PRE86="pre-fix revision $PIN_STICKY unavailable (shallow clone or rewritten history)"
git -C "$ROOT" cat-file -e "$PIN_FALSE^{commit}" 2>/dev/null \
    || MID86="revision $PIN_FALSE unavailable (shallow clone or rewritten history)"
mkdir -p "$TMP/prefix/llm2" || fail "phase 5g: cannot create the pre-fix source dir"
if [ -z "$PRE86" ]; then
    git -C "$ROOT" show "$PIN_STICKY:src/llm2/outcome.c" > "$TMP/prefix/llm2/outcome.c" 2>/dev/null \
        || PRE86="cannot extract src/llm2/outcome.c at $PIN_STICKY"
    git -C "$ROOT" show "$PIN_STICKY:src/llm2/outcome.h" > "$TMP/prefix/llm2/outcome.h" 2>/dev/null \
        || PRE86="cannot extract src/llm2/outcome.h at $PIN_STICKY"
    [ -z "$PRE86" ] && cmp -s "$TMP/prefix/llm2/outcome.c" "$ROOT/src/llm2/outcome.c" \
        && PRE86="the pinned pre-fix outcome.c is IDENTICAL to the working tree — the asymmetry arm would compare the code to itself (was the fix reverted?)"
fi
mkdir -p "$TMP/midfix/llm2" || fail "phase 5g: cannot create the mid-fix source dir"
if [ -z "$MID86" ]; then
    git -C "$ROOT" show "$PIN_FALSE:src/llm2/outcome.c" > "$TMP/midfix/llm2/outcome.c" 2>/dev/null \
        || MID86="cannot extract src/llm2/outcome.c at $PIN_FALSE"
    git -C "$ROOT" show "$PIN_FALSE:src/llm2/outcome.h" > "$TMP/midfix/llm2/outcome.h" 2>/dev/null \
        || MID86="cannot extract src/llm2/outcome.h at $PIN_FALSE"
    [ -z "$MID86" ] && cmp -s "$TMP/midfix/llm2/outcome.c" "$ROOT/src/llm2/outcome.c" \
        && MID86="the $PIN_FALSE outcome.c is IDENTICAL to the working tree — the false-run arm would compare the code to itself"
fi
# the DAMAGE-RULE pin: 014ebb7 is the committed outcome.c where a torn
# attempt + surviving result still reads RUN (the re-issuing hole).  Same
# rules: a fixed revision, a cat-file guard, and a cmp proof that the pin
# differs from the working tree (identical would mean the damage rule was
# reverted, and the fail-before arm would compare the code to itself).
PIN_ORPHAN="014ebb7"
ORPH86=""
git -C "$ROOT" cat-file -e "$PIN_ORPHAN^{commit}" 2>/dev/null \
    || ORPH86="revision $PIN_ORPHAN unavailable (shallow clone or rewritten history)"
mkdir -p "$TMP/orphfix/llm2" || fail "phase 5g: cannot create the damage-rule source dir"
if [ -z "$ORPH86" ]; then
    git -C "$ROOT" show "$PIN_ORPHAN:src/llm2/outcome.c" > "$TMP/orphfix/llm2/outcome.c" 2>/dev/null \
        || ORPH86="cannot extract src/llm2/outcome.c at $PIN_ORPHAN"
    git -C "$ROOT" show "$PIN_ORPHAN:src/llm2/outcome.h" > "$TMP/orphfix/llm2/outcome.h" 2>/dev/null \
        || ORPH86="cannot extract src/llm2/outcome.h at $PIN_ORPHAN"
    [ -z "$ORPH86" ] && cmp -s "$TMP/orphfix/llm2/outcome.c" "$ROOT/src/llm2/outcome.c" \
        && ORPH86="the $PIN_ORPHAN outcome.c is IDENTICAL to the working tree — the damage-rule arm would compare the code to itself (was the rule reverted?)"
fi
echo "== phase 5g: done ordering + torn-tail repair — unit asymmetry vs pinned pre-fix sources"
cat > "$TMP/ordprobe.c" <<'CEOF'
/* The record's ORDER and TAIL invariants, straight at the API.  argv:
 *   ordprobe done-first DIR    record(done) then record(attempt) -> verdict name
 *   ordprobe attempt-first DIR record(attempt) then record(done) -> verdict name
 *   ordprobe done-first-result DIR STORE V
 *                              record(done), record(attempt),
 *                              record(result v=V), verdict with a store whose
 *                              CURRENT is V (the C==A branch) -> verdict name
 *   ordprobe tailrepair DIR    good record + torn tail + good record -> visible|lost
 * Exit 0 always (2 on a setup error); the CALLER asserts the printed word. */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include "outcome.h"

static const char *vname(FxVerdict v) {
    switch (v) {
    case FX_VERDICT_RUN: return "RUN";
    case FX_VERDICT_ACTIVATION_FAILED: return "ACTIVATION_FAILED";
    case FX_VERDICT_ALREADY_DONE: return "ALREADY_DONE";
    case FX_VERDICT_SUPERSEDED: return "SUPERSEDED";
    case FX_VERDICT_UNRESOLVED: return "UNRESOLVED";
    default: return "ERROR";
    }
}

/* plant a store: CURRENT=cur, one optional bootlog line ("v status epoch") */
static int plant_store2(const char *st, unsigned long cur, const char *bootlog) {
    char b[4096];
    if (mkdir(st, 0755) != 0 && errno != EEXIST) return -1;
    snprintf(b, sizeof b, "%s/.db", st);
    if (mkdir(b, 0755) != 0 && errno != EEXIST) return -1;
    snprintf(b, sizeof b, "%s/.db/snapshots", st);
    if (mkdir(b, 0755) != 0 && errno != EEXIST) return -1;
    snprintf(b, sizeof b, "%s/.db/snapshots/CURRENT", st);
    FILE *f = fopen(b, "w");
    if (!f) return -1;
    fprintf(f, "%lu\n", cur);
    fclose(f);
    snprintf(b, sizeof b, "%s/.bootlog", st);
    f = fopen(b, "w");
    if (!f) return -1;
    if (bootlog && *bootlog) fprintf(f, "%s\n", bootlog);
    fclose(f);
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 3) return 2;
    const char *dir = argv[2], *task = "0123456789abcdef";
    (void)mkdir(dir, 0755);
    if (strcmp(argv[1], "done-first") == 0) {
        if (fx_outcome_record(dir, task, "done", "s1", "r1", 0, NULL) != 0) return 2;
        if (fx_outcome_record(dir, task, "attempt", "s2", "r2", 0,
                              "/fx/disk/agent-config.dhall") != 0) return 2;
        FxOutcome o; char rep[512];
        FxVerdict v = fx_outcome_verdict(dir, task, NULL, NULL, &o,
                                         rep, sizeof rep, NULL, 0);
        printf("%s\n", vname(v));
        return 0;
    }
    if (strcmp(argv[1], "attempt-first") == 0) {
        if (fx_outcome_record(dir, task, "attempt", "s1", "r1", 0,
                              "/fx/disk/agent-config.dhall") != 0) return 2;
        if (fx_outcome_record(dir, task, "done", "s1", "r1", 0, NULL) != 0) return 2;
        FxOutcome o; char rep[512];
        FxVerdict v = fx_outcome_verdict(dir, task, NULL, NULL, &o,
                                         rep, sizeof rep, NULL, 0);
        printf("%s\n", vname(v));
        return 0;
    }
    if (strcmp(argv[1], "done-first-result") == 0) {
        /* done, then a LATER attempt, then that attempt's own result at
         * version V; the store's CURRENT is V, so the verdict reaches the
         * C==A branch.  The planted store has NO bootlog (the generation is
         * never judged), exactly the state a --resume leaves behind. */
        if (argc < 5) return 2;
        unsigned long v = strtoul(argv[4], NULL, 10);
        char snap[4096], cur[4096];
        if (mkdir(argv[3], 0755) != 0 && errno != EEXIST) return 2;
        snprintf(snap, sizeof snap, "%s/.db", argv[3]);
        if (mkdir(snap, 0755) != 0 && errno != EEXIST) return 2;
        snprintf(snap, sizeof snap, "%s/.db/snapshots", argv[3]);
        if (mkdir(snap, 0755) != 0 && errno != EEXIST) return 2;
        snprintf(cur, sizeof cur, "%s/CURRENT", snap);
        FILE *cf = fopen(cur, "w");
        if (!cf) return 2;
        fprintf(cf, "%lu\n", v);
        fclose(cf);
        if (fx_outcome_record(argv[2], task, "done", "s1", "r1", 0, NULL) != 0) return 2;
        if (fx_outcome_record(argv[2], task, "attempt", "s2", "r2", 0,
                              "/fx/disk/agent-config.dhall") != 0) return 2;
        if (fx_outcome_record(argv[2], task, "result", "s2", "r2", v,
                              "/fx/disk/agent-config.dhall") != 0) return 2;
        FxOutcome o; char rep[512];
        FxVerdict vd = fx_outcome_verdict(argv[2], task, argv[3], NULL, &o,
                                          rep, sizeof rep, NULL, 0);
        printf("%s\n", vname(vd));
        return 0;
    }
    if (strcmp(argv[1], "ok-ca") == 0) {
        /* THE OVERLAPPING CELL: A ok in the bootlog AND C == A AND no done.
         * The rows are evaluated in order, so the bootlog verdict on A
         * decides before the C == A comparison: SUPERSEDED, not RUN. */
        if (argc < 5) return 2;
        unsigned long v = strtoul(argv[4], NULL, 10);
        char bl[128];
        snprintf(bl, sizeof bl, "%lu ok 1700000000", v);
        if (plant_store2(argv[3], v, bl) != 0) return 2;
        if (fx_outcome_record(argv[2], task, "attempt", "s1", "r1", 0,
                              "/fx/disk/agent-config.dhall") != 0) return 2;
        if (fx_outcome_record(argv[2], task, "result", "s1", "r1", v,
                              "/fx/disk/agent-config.dhall") != 0) return 2;
        FxOutcome o; char rep[512];
        FxVerdict vd = fx_outcome_verdict(argv[2], task, argv[3], NULL, &o,
                                          rep, sizeof rep, NULL, 0);
        printf("%s\n", vname(vd));
        return 0;
    }
    if (strcmp(argv[1], "dar-cneqa") == 0) {
        /* done -> attempt -> result at C != A: the reinstated done must not
         * leak a completion claim into the never-judged row. */
        if (argc < 5) return 2;
        unsigned long v = strtoul(argv[4], NULL, 10);
        if (plant_store2(argv[3], 9, NULL) != 0) return 2; /* C = 9 != A */
        if (fx_outcome_record(argv[2], task, "done", "s1", "r1", 0, NULL) != 0) return 2;
        if (fx_outcome_record(argv[2], task, "attempt", "s2", "r2", 0,
                              "/fx/disk/agent-config.dhall") != 0) return 2;
        if (fx_outcome_record(argv[2], task, "result", "s2", "r2", v,
                              "/fx/disk/agent-config.dhall") != 0) return 2;
        FxOutcome o; char rep[512];
        FxVerdict vd = fx_outcome_verdict(argv[2], task, argv[3], NULL, &o,
                                          rep, sizeof rep, NULL, 0);
        printf("%s\n", vname(vd));
        return 0;
    }
    if (strcmp(argv[1], "v0-reinstate") == 0) {
        /* a result naming NO generation (v0) still ACCOUNTS the attempt, so
         * the suspended done returns to force.  Needs no store: the
         * unaccounted branch is decided before any store read. */
        if (fx_outcome_record(argv[2], task, "done", "s1", "r1", 0, NULL) != 0) return 2;
        if (fx_outcome_record(argv[2], task, "attempt", "s2", "r2", 0,
                              "/fx/disk/agent-config.dhall") != 0) return 2;
        if (fx_outcome_record(argv[2], task, "result", "s2", "r2", 0,
                              "/fx/disk/agent-config.dhall") != 0) return 2;
        FxOutcome o; char rep[512];
        FxVerdict vd = fx_outcome_verdict(argv[2], task, NULL, NULL, &o,
                                          rep, sizeof rep, NULL, 0);
        printf("%s\n", vname(vd));
        return 0;
    }
    if (strcmp(argv[1], "torn-attempt") == 0) {
        /* THE DAMAGE RULE: the attempt line torn mid-step-token (an ENOSPC
         * partial write), then the result write SUCCEEDS — the writer's
         * tail repair closes the torn prefix as its own unparsable line and
         * the result lands complete.  The attempt is unreadable; the result
         * is an ORPHAN.  Line 1: the verdict; line 2: the report (asserted
         * to name the escape). */
        char path[1024];
        snprintf(path, sizeof path, "%s/attempts.jsonl", dir);
        FILE *f = fopen(path, "ab");
        if (!f) return 2;
        fputs("1700000000 ", f); fputs(task, f); fputs(" at", f); /* torn "attempt" */
        fclose(f);
        if (fx_outcome_record(dir, task, "result", "s1", "r1", 5,
                              "/fx/disk/agent-config.dhall") != 0) return 2;
        FxOutcome o; char rep[1024];
        FxVerdict vd = fx_outcome_verdict(dir, task, NULL, NULL, &o,
                                          rep, sizeof rep, NULL, 0);
        printf("%s\n%s\n", vname(vd), rep);
        return 0;
    }
    if (strcmp(argv[1], "torn-attempt-tail") == 0) {
        /* the torn attempt is the LAST line (no repair, no result): the
         * torn-line flag itself must forbid RUN — its visible counterpart
         * (a complete attempt with no result) is UNRESOLVED too. */
        char path[1024];
        snprintf(path, sizeof path, "%s/attempts.jsonl", dir);
        FILE *f = fopen(path, "ab");
        if (!f) return 2;
        fputs("1700000000 ", f); fputs(task, f); fputs(" at", f);
        fclose(f);
        FxOutcome o; char rep[512];
        FxVerdict vd = fx_outcome_verdict(dir, task, NULL, NULL, &o,
                                          rep, sizeof rep, NULL, 0);
        printf("%s\n", vname(vd));
        return 0;
    }
    if (strcmp(argv[1], "orphan-done") == 0) {
        /* the DECISION half: a done in force is positive evidence and is
         * NOT poisoned — ALREADY_DONE before and after the damage rule. */
        if (fx_outcome_record(dir, task, "done", "s1", "r1", 0, NULL) != 0) return 2;
        char path[1024];
        snprintf(path, sizeof path, "%s/attempts.jsonl", dir);
        FILE *f = fopen(path, "ab");
        if (!f) return 2;
        fputs("1700000000 ", f); fputs(task, f); fputs(" at", f);
        fclose(f);
        if (fx_outcome_record(dir, task, "result", "s1", "r1", 5,
                              "/fx/disk/agent-config.dhall") != 0) return 2;
        FxOutcome o; char rep[512];
        FxVerdict vd = fx_outcome_verdict(dir, task, NULL, NULL, &o,
                                          rep, sizeof rep, NULL, 0);
        printf("%s\n", vname(vd));
        return 0;
    }
    if (strcmp(argv[1], "tailrepair") == 0) {
        const char *t2 = "9999999999999999";
        if (fx_outcome_record(dir, task, "attempt", "s1", "r1", 0, "a") != 0) return 2;
        /* a torn tail: a prefix with NO terminating newline (crash mid-write) */
        char path[1024];
        snprintf(path, sizeof path, "%s/attempts.jsonl", dir);
        FILE *f = fopen(path, "ab");
        if (!f) return 2;
        fputs("1700000000 ", f); fputs(t2, f); fputs(" resul", f); /* torn: "result" cut */
        fclose(f);
        /* the NEXT record must not merge into the torn prefix */
        if (fx_outcome_record(dir, t2, "attempt", "s1", "r1", 0, "b") != 0) return 2;
        FxOutcome o;
        /* this probe is built against BOTH the pinned pre-fix sources and
         * this tree; the err-params signature arrived with the unreadable-
         * record state, so the macro that came with it selects the arity */
#ifdef FX_OUTCOME_ERR_CAP
        if (fx_outcome_record_load(dir, t2, &o, NULL, 0) != 0) return 2;
#else
        if (fx_outcome_record_load(dir, t2, &o) != 0) return 2;
#endif
        printf("%s\n", o.has_attempt ? "visible" : "lost");
        return 0;
    }
    return 2;
}
CEOF
PFXV="$TMP/ordprobe-prefix"; FIXV="$TMP/ordprobe-fixed"; MIDV="$TMP/ordprobe-midfix"
cc -std=c11 -O2 -Wall -Wextra -I"$ROOT/src" -I"$ROOT/src/llm2" \
   -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE \
   -o "$FIXV" "$TMP/ordprobe.c" "$ROOT/src/llm2/outcome.c" \
   || fail "phase 5g: cannot build the order probe against this tree"
if [ -z "$PRE86" ]; then
    cc -std=c11 -O2 -Wall -Wextra -I"$TMP/prefix/llm2" \
       -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE \
       -o "$PFXV" "$TMP/ordprobe.c" "$TMP/prefix/llm2/outcome.c" \
       || fail "phase 5g: cannot build the order probe against $PIN_STICKY's outcome.c"
else
    echo "SKIP outcome: phase 5g (pre-fix arm): $PRE86"
fi
if [ -z "$MID86" ]; then
    cc -std=c11 -O2 -Wall -Wextra -I"$TMP/midfix/llm2" \
       -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE \
       -o "$MIDV" "$TMP/ordprobe.c" "$TMP/midfix/llm2/outcome.c" \
       || fail "phase 5g: cannot build the order probe against $PIN_FALSE's outcome.c"
else
    echo "SKIP outcome: phase 5g (false-run arm): $MID86"
fi
ORPHV="$TMP/ordprobe-orphan"
if [ -z "$ORPH86" ]; then
    cc -std=c11 -O2 -Wall -Wextra -I"$TMP/orphfix/llm2" \
       -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE \
       -o "$ORPHV" "$TMP/ordprobe.c" "$TMP/orphfix/llm2/outcome.c" \
       || fail "phase 5g: cannot build the order probe against $PIN_ORPHAN's outcome.c"
else
    echo "SKIP outcome: phase 5g (damage-rule arm): $ORPH86"
fi
if [ -z "$PRE86" ]; then
W=$("$PFXV" done-first "$TMP/od-pre") || fail "phase 5g: pre-fix done-first probe failed"
[ "$W" = "ALREADY_DONE" ] \
    || fail "phase 5g: the PRE-FIX loader no longer shows the position-blind done ('$W') — the asymmetry probe proves nothing"
fi
W=$("$FIXV" done-first "$TMP/od-fix") || fail "phase 5g: fixed done-first probe failed"
[ "$W" = "UNRESOLVED" ] \
    || fail "phase 5g: the fixed loader let a done that PREDATES the attempt settle it ('$W')"
if [ -z "$PRE86" ]; then
W=$("$PFXV" attempt-first "$TMP/od-ord-pre") || fail "phase 5g: pre-fix attempt-first probe failed"
[ "$W" = "ALREADY_DONE" ] || fail "phase 5g: the ordinary attempt-then-done order broke ('$W')"
fi
W=$("$FIXV" attempt-first "$TMP/od-ord-fix") || fail "phase 5g: fixed attempt-first probe failed"
[ "$W" = "ALREADY_DONE" ] \
    || fail "phase 5g: the fix changed the ORDINARY attempt-then-done case ('$W') — a genuine completion became a re-run"
# done -> attempt -> result(v5) at C==v5: 648984f returned RUN (the FALSE
# RUN); the working loader reinstates the done -> ALREADY_DONE.  Both
# directions asserted; each fails if the reinstatement (or its absence)
# regresses.
if [ -z "$MID86" ]; then
W=$("$MIDV" done-first-result "$TMP/od-dfr-mid" "$TMP/od-dfr-store-mid" 5) \
    || fail "phase 5g: $PIN_FALSE done-first-result probe failed"
[ "$W" = "RUN" ] \
    || fail "phase 5g: $PIN_FALSE no longer returns the FALSE RUN at C==A for done->attempt->result ('$W') — the asymmetry probe proves nothing"
fi
W=$("$FIXV" done-first-result "$TMP/od-dfr-fix" "$TMP/od-dfr-store-fix" 5) \
    || fail "phase 5g: fixed done-first-result probe failed"
[ "$W" = "ALREADY_DONE" ] \
    || fail "phase 5g: done->attempt->result at C==A returned RUN ('$W') — a FALSE RUN re-issues an activation for a task the record says COMPLETED"
# and the attempt the result ACCOUNTS for is the only one a done can be
# reinstated behind: a SECOND, unaccounted attempt after the result must
# still read UNRESOLVED (the done is suspended again, not sticky).
rm -rf "$TMP/od-susp2" "$TMP/od-susp2-store"
"$FIXV" done-first-result "$TMP/od-susp2" "$TMP/od-susp2-store" 5 >/dev/null \
    || fail "phase 5g: suspension setup failed"
printf '1700000001 %s attempt s3 r3 0 /fx/disk/agent-config.dhall\n' "0123456789abcdef" >> "$TMP/od-susp2/attempts.jsonl"
cat > "$TMP/suspprobe.c" <<'CEOF'
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <string.h>
#include "outcome.h"
static const char *vname(FxVerdict v) {
    switch (v) {
    case FX_VERDICT_RUN: return "RUN";
    case FX_VERDICT_ACTIVATION_FAILED: return "ACTIVATION_FAILED";
    case FX_VERDICT_ALREADY_DONE: return "ALREADY_DONE";
    case FX_VERDICT_SUPERSEDED: return "SUPERSEDED";
    case FX_VERDICT_UNRESOLVED: return "UNRESOLVED";
    default: return "ERROR";
    }
}
int main(int argc, char **argv) {
    if (argc < 3) return 2;
    FxOutcome o; char rep[512];
    FxVerdict v = fx_outcome_verdict(argv[1], "0123456789abcdef", argv[2], NULL,
                                     &o, rep, sizeof rep, NULL, 0);
    printf("%s\n", vname(v));
    return 0;
}
CEOF
cc -std=c11 -O2 -Wall -Wextra -I"$ROOT/src" -I"$ROOT/src/llm2" \
   -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE \
   -o "$TMP/suspprobe" "$TMP/suspprobe.c" "$ROOT/src/llm2/outcome.c" \
   || fail "phase 5g: cannot build the suspension probe"
W=$("$TMP/suspprobe" "$TMP/od-susp2" "$TMP/od-susp2-store") \
    || fail "phase 5g: suspension probe failed"
[ "$W" = "UNRESOLVED" ] \
    || fail "phase 5g: a done did not re-suspend behind a SECOND unaccounted attempt ('$W') — sticky done is back"
# ── the cells the ordering review found ungated (all four, each with its
#    fail direction named in the ordprobe comment above) ──
W=$("$FIXV" ok-ca "$TMP/od-okca" "$TMP/od-okca-store" 5) \
    || fail "phase 5g: overlapping-cell probe failed"
[ "$W" = "SUPERSEDED" ] \
    || fail "phase 5g: the OVERLAPPING CELL (A ok, C==A, no done) returned '$W' — row precedence changed (want SUPERSEDED, the ok row decides before C==A)"
W=$("$FIXV" dar-cneqa "$TMP/od-dar-cna" "$TMP/od-dar-cna-store" 5) \
    || fail "phase 5g: done-attempt-result-at-C!=A probe failed"
[ "$W" = "UNRESOLVED" ] \
    || fail "phase 5g: done->attempt->result at C!=A returned '$W' (want UNRESOLVED — the never-judged row must stay conservative even with a done in force)"
W=$("$FIXV" v0-reinstate "$TMP/od-v0r") \
    || fail "phase 5g: v0-reinstatement probe failed"
[ "$W" = "ALREADY_DONE" ] \
    || fail "phase 5g: done->attempt->result(v0) returned '$W' (want ALREADY_DONE — a result naming no generation still accounts the attempt)"
# ── THE DAMAGE RULE: torn attempt + surviving result ──
if [ -z "$ORPH86" ]; then
W=$("$ORPHV" torn-attempt "$TMP/od-torn-pre") \
    || fail "phase 5g: $PIN_ORPHAN torn-attempt probe failed"
[ "$W" = "RUN" ] \
    || fail "phase 5g: $PIN_ORPHAN no longer returns RUN for a torn attempt + surviving result ('$W') — the asymmetry probe proves nothing"
W=$("$ORPHV" torn-attempt-tail "$TMP/od-torntail-pre") \
    || fail "phase 5g: $PIN_ORPHAN torn-attempt-tail probe failed"
[ "$W" = "RUN" ] \
    || fail "phase 5g: $PIN_ORPHAN no longer returns RUN for a torn attempt as the last line ('$W')"
fi
"$FIXV" torn-attempt "$TMP/od-torn-fix" > "$TMP/od-torn-fix.out" \
    || fail "phase 5g: fixed torn-attempt probe failed"
W=$(head -1 "$TMP/od-torn-fix.out")
[ "$W" = "UNRESOLVED" ] \
    || fail "phase 5g: a torn attempt + surviving result returned '$W' (want UNRESOLVED — never RUN off a record that provably lost a line)"
assert_escape "phase 5g (damaged record)" "$(tail -n +2 "$TMP/od-torn-fix.out")"
printf '%s\n' "$(tail -n +2 "$TMP/od-torn-fix.out")" | grep -q "DAMAGED" \
    || { cat "$TMP/od-torn-fix.out" >&2; fail "phase 5g: the damaged-record report does not say the record is damaged"; }
W=$("$FIXV" torn-attempt-tail "$TMP/od-torntail-fix") \
    || fail "phase 5g: fixed torn-attempt-tail probe failed"
[ "$W" = "UNRESOLVED" ] \
    || fail "phase 5g: a torn attempt as the last line returned '$W' (want UNRESOLVED — the torn line proves mid-write)"
W=$("$FIXV" orphan-done "$TMP/od-orphan-done") \
    || fail "phase 5g: orphan-done probe failed"
[ "$W" = "ALREADY_DONE" ] \
    || fail "phase 5g: done + torn attempt + orphan result returned '$W' (want ALREADY_DONE — a done in force is positive evidence and is NOT poisoned; changing this verdict is a DECISION change, see outcome.h)"
if [ -z "$ORPH86" ]; then
W=$("$ORPHV" orphan-done "$TMP/od-orphan-done-pre") \
    || fail "phase 5g: $PIN_ORPHAN orphan-done probe failed"
[ "$W" = "ALREADY_DONE" ] \
    || fail "phase 5g: $PIN_ORPHAN reads '$W' for done + torn attempt + orphan result (want ALREADY_DONE — the rule must have changed the cell it promised not to)"
fi
if [ -z "$PRE86" ]; then
W=$("$PFXV" tailrepair "$TMP/tr-pre") || fail "phase 5g: pre-fix tailrepair probe failed"
[ "$W" = "lost" ] \
    || fail "phase 5g: the PRE-FIX writer did not merge the next record into the torn tail ('$W') — the asymmetry probe proves nothing"
fi
W=$("$FIXV" tailrepair "$TMP/tr-fix") || fail "phase 5g: fixed tailrepair probe failed"
[ "$W" = "visible" ] \
    || fail "phase 5g: a record appended after a torn tail was LOST ('$W') — the next boot would read nothing and RUN"
note "unit asymmetry: done-before-attempt ALREADY_DONE(pre-fix) -> UNRESOLVED(fixed); done->attempt->RESULT RUN(648984f) -> ALREADY_DONE(fixed) and re-suspended behind a second unaccounted attempt; attempt-then-done unchanged; a torn tail no longer eats the next record"
note "ungated cells now pinned: (ok, C==A, no done) -> SUPERSEDED by precedence; d-a-r at C!=A -> UNRESOLVED; d-a-r(v0) -> ALREADY_DONE; and the DAMAGE RULE: torn attempt + surviving result RUN(014ebb7) -> UNRESOLVED(fixed), torn tail alone -> UNRESOLVED, done-in-force NOT poisoned (ALREADY_DONE, before and after)"

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

# ── phase 8: the tool-table bound — fx_write's surface is HOST-DECLARED ────
# The review measured the hole at tools/fx-verbs-server.c native_write: it
# resolved an ARBITRARY path under FX_VERB_ROOT and opened it O_TRUNC, so a
# model could fx_read the record, learn its task id, and fx_write the record
# back without its own lines — the next boot sees no attempt, decides RUN and
# re-issues the crasher: the oscillator resurrected by a motivated model.
# The loop's guarantee is now a FACT OF THE TOOL TABLE (outside the guest a
# tool vocabulary is a policy; inside it is a fact): fx_write may write ONLY
# the exact paths in the host-declared FX_AGENT_WRITABLE set, and the record
# directory and the store are in NO default set.  ASYMMETRY, both directions,
# against the PRE-FIX server built from the committed source: the record-path
# write SUCCEEDS before the fix (the hole, re-measured here) and is REFUSED
# after it, while the task-config write STILL SUCCEEDS after — a fix that
# refuses everything is not a fix.
echo "== phase 8: fx_write writes ONLY the host-declared set (record refused, config allowed)"
# The pre-fix server is PINNED (never HEAD — see phase 5g's pinning note) and
# its DOMAIN asserted: the pinned source must actually DIFFER from the
# working one, or the arm would compare the code to itself.
if [ -z "$PRE86" ]; then
    mkdir -p "$TMP/prefix/tools" || fail "phase 8: cannot create the pre-fix source dir"
    git -C "$ROOT" show "$PIN_STICKY:tools/fx-verbs-server.c" > "$TMP/prefix/tools/fx-verbs-server.c" 2>/dev/null \
        || PRE86="cannot extract tools/fx-verbs-server.c at $PIN_STICKY"
    [ -z "$PRE86" ] && cmp -s "$TMP/prefix/tools/fx-verbs-server.c" "$ROOT/tools/fx-verbs-server.c" \
        && PRE86="the pinned pre-fix fx-verbs-server.c is IDENTICAL to the working tree"
fi
if [ -n "$PRE86" ]; then
    echo "SKIP outcome: phase 8 (pre-fix arms): $PRE86"
else
cc -std=c11 -O2 -Wall -Wextra -I"$TMP/prefix" -I"$ROOT/src/vendor/yyjson" \
   -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE \
   -o "$TMP/vs-prefix" "$TMP/prefix/tools/fx-verbs-server.c" \
   "$TMP/prefix/llm2/outcome.c" "$ROOT/src/vendor/yyjson/yyjson.c" \
   || fail "phase 8: cannot build the pre-fix fx-verbs-server"
fi
# the 648984f server for the DOCUMENTED-SPELLING asymmetry: that commit's
# docs (and its model-facing tool description) said entries are root-relative
# while only absolute entries ever matched — a deployment following its own
# documentation got a fail-closed agent that could not write its own config.
if [ -z "$MID86" ]; then
    mkdir -p "$TMP/midfix/tools" || fail "phase 8: cannot create the mid-fix source dir"
    git -C "$ROOT" show "$PIN_FALSE:tools/fx-verbs-server.c" > "$TMP/midfix/tools/fx-verbs-server.c" 2>/dev/null \
        || MID86="cannot extract tools/fx-verbs-server.c at $PIN_FALSE"
    [ -z "$MID86" ] && cmp -s "$TMP/midfix/tools/fx-verbs-server.c" "$ROOT/tools/fx-verbs-server.c" \
        && MID86="the $PIN_FALSE fx-verbs-server.c is IDENTICAL to the working tree"
fi
if [ -n "$MID86" ]; then
    echo "SKIP outcome: phase 8 (documented-spelling arm): $MID86"
else
cc -std=c11 -O2 -Wall -Wextra -I"$TMP/midfix" -I"$ROOT/src/vendor/yyjson" \
   -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE \
   -o "$TMP/vs-midfix" "$TMP/midfix/tools/fx-verbs-server.c" \
   "$TMP/midfix/llm2/outcome.c" "$ROOT/src/vendor/yyjson/yyjson.c" \
   || fail "phase 8: cannot build the $PIN_FALSE fx-verbs-server"
fi
WR="$TMP/wroot"                       # the model's view: FX_VERB_ROOT
WRP="$TMP/wroot-prefix"               # the PRE-FIX server's own root
mkdir -p "$WR/fx/disk/agent-data" "$WRP/fx/disk/agent-data" \
    || fail "phase 8: cannot lay out the writable-set roots"
printf 'PRE-EXISTING RECORD LINE\n' > "$WRP/fx/disk/agent-data/attempts.jsonl"
printf 'PRE-EXISTING RECORD LINE\n' > "$WR/fx/disk/agent-data/attempts.jsonl"
WS_ENV="FX_AGENT_WRITABLE=/fx/disk/agent-config.dhall"
drive() { # drive BIN ROOT ENVEXTRA PATH CONTENT -> "exitcode\nreply-text"
    _b=$1 _r=$2 _e=$3 _p=$4 _c=$5
    # `env` (not a shell assignment prefix): $_e expands AFTER parsing, so an
    # assignment-prefix would be taken as the command name.
    env FX_VERB_ROOT="$_r" $_e python3 - "$_b" "$_p" "$_c" <<'PYEOF' || fail "phase 8: driver failed"
import json, os, subprocess, sys
srv = subprocess.Popen([sys.argv[1]], stdin=subprocess.PIPE,
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
def req(obj):
    srv.stdin.write((json.dumps(obj) + "\n").encode()); srv.stdin.flush()
    return srv.stdout.readline().decode()
req({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
srv.stdin.write((json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}}) + "\n").encode()); srv.stdin.flush()
d = json.loads(req({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                    "params": {"name": "fx_write",
                               "arguments": {"path": sys.argv[2],
                                             "content": sys.argv[3]}}}))
srv.stdin.close(); srv.wait(timeout=5)
text = d["result"]["content"][0]["text"]
sys.stdout.write(text)
PYEOF
}
# BEFORE (the hole, re-measured): the pinned pre-fix server writes the RECORD path.
if [ -z "$PRE86" ]; then
TXT=$(drive "$TMP/vs-prefix" "$WRP" "$WS_ENV" /fx/disk/agent-data/attempts.jsonl 'FORGED-RECORD-LINE')
case "$TXT" in exit=0*) ;; *) printf '%s\n' "$TXT" >&2
    fail "phase 8: the PRE-FIX server did NOT write the record path — the asymmetry probe proves nothing";; esac
grep -q 'FORGED-RECORD-LINE' "$WRP/fx/disk/agent-data/attempts.jsonl" \
    || fail "phase 8: the PRE-FIX write of the record did not land (probe is vacuous)"
note "pre-fix: the record path was WRITABLE (the hole, measured): $(printf '%s\n' "$TXT" | head -1)"
fi
# AFTER: the fixed server REFUSES the record path, LOUDLY.
TXT=$(drive "$VS" "$WR" "$WS_ENV" /fx/disk/agent-data/attempts.jsonl 'FORGED-RECORD-LINE')
case "$TXT" in exit=1*) ;; *) printf '%s\n' "$TXT" >&2
    fail "phase 8: fx_write on the record path did not exit 1 — the writable set does not hold";; esac
printf '%s\n' "$TXT" | grep -q "fx/disk/agent-data/attempts.jsonl" \
    || { printf '%s\n' "$TXT" >&2; fail "phase 8: the refusal does not NAME the path"; }
printf '%s\n' "$TXT" | grep -q "FX_AGENT_WRITABLE" \
    || { printf '%s\n' "$TXT" >&2; fail "phase 8: the refusal does not NAME the set"; }
printf '%s\n' "$TXT" | grep -q "host-declared" \
    || { printf '%s\n' "$TXT" >&2; fail "phase 8: the refusal does not say the set is host-declared"; }
grep -q 'PRE-EXISTING RECORD LINE' "$WR/fx/disk/agent-data/attempts.jsonl" \
    || fail "phase 8: the refused write MODIFIED the record"
grep -q 'FORGED-RECORD-LINE' "$WR/fx/disk/agent-data/attempts.jsonl" \
    && fail "phase 8: the refused write LANDED in the record"
note "fixed: the record path is REFUSED (exit 1, path + set + host-declared named), file untouched"
# AFTER: the TASK CONFIG path (the one path the harness tells the agent to
# write) STILL SUCCEEDS — the other direction of the asymmetry.
TXT=$(drive "$VS" "$WR" "$WS_ENV" /fx/disk/agent-config.dhall 'let x = 1 in x')
case "$TXT" in exit=0*) ;; *) printf '%s\n' "$TXT" >&2
    fail "phase 8: fx_write on the TASK CONFIG path was refused — the fix broke the product to close the hole";; esac
[ "$(cat "$WR/fx/disk/agent-config.dhall")" = 'let x = 1 in x' ] \
    || fail "phase 8: the allowed write did not land"
note "fixed: the task-config write still succeeds (exit 0, content round-trips)"
# AFTER, THE DOCUMENTED SPELLING: FX_AGENT_WRITABLE entered ROOT-RELATIVELY
# (the spelling 648984f's comments and model-facing description document)
# must grant the config write — and 648984f itself refused it (the entry was
# silently dropped, the set behaved as empty), which is the fail-closed
# deployment bug this round fixes.  Both directions pinned.
if [ -z "$MID86" ]; then
TXT=$(drive "$TMP/vs-midfix" "$WR" "FX_AGENT_WRITABLE=fx/disk/agent-config.dhall" /fx/disk/agent-config.dhall 'let m = 3 in m')
case "$TXT" in exit=1*) ;; *) printf '%s\n' "$TXT" >&2
    fail "phase 8: $PIN_FALSE ACCEPTED the documented root-relative entry — the spelling asymmetry probe proves nothing";; esac
note "648984f: the documented root-relative entry was REFUSED (the doc bug, measured): $(printf '%s\n' "$TXT" | head -1)"
fi
TXT=$(drive "$VS" "$WR" "FX_AGENT_WRITABLE=fx/disk/agent-config.dhall" /fx/disk/agent-config.dhall 'let m = 3 in m')
case "$TXT" in exit=0*) ;; *) printf '%s\n' "$TXT" >&2
    fail "phase 8: the DOCUMENTED root-relative entry no longer grants the config write — the docs and the code disagree again";; esac
[ "$(cat "$WR/fx/disk/agent-config.dhall")" = 'let m = 3 in m' ] \
    || fail "phase 8: the documented-spelling write did not land"
note "fixed: the documented root-relative entry grants exactly the config path (exit 0, content round-trips)"
# AFTER, THE ALLOWED '..' DIRECTION: a '..' spelling that canonicalizes ONTO
# an allowed member must still WRITE (an over-refusing regression — refusing
# any path that merely CONTAINS '..' — would pass every refused-direction
# probe above).
TXT=$(drive "$VS" "$WR" "$WS_ENV" /fx/disk/agent-config.dhall/../agent-config.dhall 'let d = 4 in d')
case "$TXT" in exit=0*) ;; *) printf '%s\n' "$TXT" >&2
    fail "phase 8: a '..' spelling ONTO an allowed member was refused — the fix broke a legitimate case";; esac
[ "$(cat "$WR/fx/disk/agent-config.dhall")" = 'let d = 4 in d' ] \
    || fail "phase 8: the allowed-'..' write did not land"
note "fixed: a '..' spelling onto an allowed member still writes (over-refusal caught)"
# AFTER: a '..' spelling cannot reach around the set (the membership check
# runs on the CANONICALIZED path, so this spelling names exactly the record).
TXT=$(drive "$VS" "$WR" "$WS_ENV" /fx/disk/agent-config.dhall/../agent-data/attempts.jsonl 'FORGED-RECORD-LINE')
case "$TXT" in exit=1*) ;; *) printf '%s\n' "$TXT" >&2
    fail "phase 8: a '..' spelling reached around the writable set";; esac
grep -q 'FORGED-RECORD-LINE' "$WR/fx/disk/agent-data/attempts.jsonl" \
    && fail "phase 8: the traversal write LANDED in the record"
# AFTER, DEFAULT: with FX_AGENT_WRITABLE UNSET the set is exactly the task
# config path — never "unrestricted", and never the record.
TXT=$(drive "$VS" "$WR" "" /fx/disk/agent-config.dhall 'let y = 2 in y')
case "$TXT" in exit=0*) ;; *) printf '%s\n' "$TXT" >&2
    fail "phase 8: the DEFAULT set no longer contains the task config path";; esac
TXT=$(drive "$VS" "$WR" "" /fx/disk/agent-data/attempts.jsonl 'FORGED-RECORD-LINE')
case "$TXT" in exit=1*) ;; *) printf '%s\n' "$TXT" >&2
    fail "phase 8: with FX_AGENT_WRITABLE unset, the record path was WRITABLE — the default re-opens the hole";; esac
note "fixed, default (unset): exactly the task config is writable; the record still is not"
# READS STAY OPEN (the honest bound, asserted so it cannot drift): the record
# is not a secret, and fx_read settling nothing is the design (outcome.h).
TXT=$(FX_VERB_ROOT="$WR" python3 - "$VS" <<'PYEOF' || fail "phase 8: read driver failed"
import json, subprocess, sys
srv = subprocess.Popen([sys.argv[1]], stdin=subprocess.PIPE,
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
def req(obj):
    srv.stdin.write((json.dumps(obj) + "\n").encode()); srv.stdin.flush()
    return srv.stdout.readline().decode()
req({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
srv.stdin.write((json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}}) + "\n").encode()); srv.stdin.flush()
d = json.loads(req({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                    "params": {"name": "fx_read",
                               "arguments": {"path": "/fx/disk/agent-data/attempts.jsonl"}}}))
srv.stdin.close(); srv.wait(timeout=5)
sys.stdout.write(d["result"]["content"][0]["text"])
PYEOF
)
case "$TXT" in exit=0*) ;; *) printf '%s\n' "$TXT" >&2
    fail "phase 8: fx_read of the record failed — the comment states reads are open; the code must match it";; esac
printf '%s\n' "$TXT" | grep -q 'PRE-EXISTING RECORD LINE' \
    || { printf '%s\n' "$TXT" >&2; fail "phase 8: fx_read did not return the record's content"; }
note "fx_read of the record still works (reads are open by design — the bound is on WRITE)"

# ── phase 9: THE RECOVERY JOURNAL — the agent sees that it has happened ═══
# BEFORE, not merely that it happened.  fx-init 4d6a8c2 writes <store>/.recovery
# (one data line per AUTOMATIC roll-forward); until this phase nothing read it,
# and a seat that is never called is indistinguishable from an absent seat.
# Two surfaces, both asserted here: the ACTIVATION_FAILED report (what a refused
# agent sees at boot — the qemu observe gate's boot 3 never dispatches the
# fixture, so the report is the only place that agent can see the count) and
# the fx_outcome verb (what the model can call).  Each sub-phase names what
# makes it FAIL.
echo "== phase 9: the recovery journal — counted, distinct from absent, floor on torn, surfaced twice"
# 9a — a journal with a RECURRENCE: the report must carry the count, the
# newest recovery, and the same-genhash signal with the journal's own honesty
# limit.  FAILS if the reader ignores .recovery (no recovery line at all), if
# it counts the header (wrong number), or if it prints a recurrence without
# the not-a-live-oscillation bound.
newdata
plant_store 9 "8 in-progress 1700000000" "8 failed 1700000020" "9 in-progress 1700000030"
plant_journal "1791556214 9 7 feedface0123456789abcdef" "1791556300 11 9 feedface0123456789abcdef"
record "1700000000 $TASK attempt - - 0 /fx/disk/agent-config.dhall"
record "1700000000 $TASK result - - 8 /fx/disk/agent-config.dhall"
out=$(run "$BIN" --store "$STORE"); rc=$?
[ "$rc" = 0 ] || fail "phase 9a: rc=$rc (want 0 — the journal must not change the refusal's exit)"
echo "$out" | grep -q "THE ACTIVATION THIS HARNESS RECORDED FAILED" \
    || { echo "$out" >&2; fail "phase 9a: the journal changed the VERDICT — it must be information, never a rule input"; }
echo "$out" | grep -q "2 automatic roll-forward(s) on record" \
    || { echo "$out" >&2; fail "phase 9a: the report does not carry the journal COUNT (a store with a journal must read as COUNTED)"; }
echo "$out" | grep -q "feedface0123456789abcdef has failed 2 time(s)" \
    || { echo "$out" >&2; fail "phase 9a: the report does not say the SAME GENHASH recurs (the signal the journal exists for)"; }
echo "$out" | grep -q "THE SAME FAULT RETURNING, not a live-oscillation" \
    || { echo "$out" >&2; fail "phase 9a: the recurrence is stated without the journal's own honesty limit (a number implying oscillation)"; }
echo "$out" | grep -q "newest: v11 republished from v9" \
    || { echo "$out" >&2; fail "phase 9a: the report does not name the LAST recovery (published/from pair)"; }
# 9b — ABSENT journal is a DIFFERENT claim than zero, and it is NOT an error:
# FAILS if absence becomes a failure (no report at all), or if the wording
# collapses absent into zero (the weaker claim standing in for "unknown").
newdata
plant_store 9 "8 in-progress 1700000000" "8 failed 1700000020" "9 in-progress 1700000030"
rm -f "$STORE/.recovery"
record "1700000000 $TASK attempt - - 0 /fx/disk/agent-config.dhall"
record "1700000000 $TASK result - - 8 /fx/disk/agent-config.dhall"
out=$(run "$BIN" --store "$STORE"); rc=$?
[ "$rc" = 0 ] || fail "phase 9b: rc=$rc (an absent journal must not be an error)"
echo "$out" | grep -q "THE ACTIVATION THIS HARNESS RECORDED FAILED" \
    || { echo "$out" >&2; fail "phase 9b: the verdict changed on an absent journal"; }
echo "$out" | grep -q "no .recovery on this store" \
    || { echo "$out" >&2; fail "phase 9b: the report does not say the journal is ABSENT"; }
echo "$out" | grep -q "UNKNOWN, not zero" \
    || { echo "$out" >&2; fail "phase 9b: absent is not worded as the DISTINCT claim it is (unknown vs zero)"; }
echo "$out" | grep -q "0 automatic roll-forwards" \
    && { echo "$out" >&2; fail "phase 9b: an ABSENT journal read as ZERO — two different claims collapsed"; }
# 9c — a TORN last line: skipped (the rest still counted) and SAID (the count
# is a floor).  FAILS if the torn prefix is counted (a truncated genhash is
# not a recovery) or silently dropped (a floor presented as exact).
newdata
plant_store 9 "8 in-progress 1700000000" "8 failed 1700000020" "9 in-progress 1700000030"
plant_journal "1791556214 9 7 feedface0123456789abcdef" "1791556300 11 9 feedface0123456789abcdef"
printf '%s' "1791556500 15 13 feedfa" >> "$STORE/.recovery"   # torn: no newline
record "1700000000 $TASK attempt - - 0 /fx/disk/agent-config.dhall"
record "1700000000 $TASK result - - 8 /fx/disk/agent-config.dhall"
out=$(run "$BIN" --store "$STORE"); rc=$?
[ "$rc" = 0 ] || fail "phase 9c: rc=$rc"
echo "$out" | grep -q "2 automatic roll-forward(s) on record" \
    || { echo "$out" >&2; fail "phase 9c: the torn line was counted, or the complete lines were lost"; }
echo "$out" | grep -q "the count is a FLOOR" \
    || { echo "$out" >&2; fail "phase 9c: a torn line was skipped WITHOUT saying the count is a floor"; }
# 9d — a journal that has NEVER recorded a recovery: ZERO is a measurement,
# and it must not read as an absence.  FAILS if the zero wording disappears
# (or is replaced by the absent wording).
newdata
plant_store 9 "8 in-progress 1700000000" "8 failed 1700000020" "9 in-progress 1700000030"
plant_journal
record "1700000000 $TASK attempt - - 0 /fx/disk/agent-config.dhall"
record "1700000000 $TASK result - - 8 /fx/disk/agent-config.dhall"
out=$(run "$BIN" --store "$STORE"); rc=$?
[ "$rc" = 0 ] || fail "phase 9d: rc=$rc"
echo "$out" | grep -q "0 automatic roll-forwards on record" \
    || { echo "$out" >&2; fail "phase 9d: a present-but-empty journal does not read as ZERO"; }
echo "$out" | grep -q "the FIRST time this machine has had to recover" \
    || { echo "$out" >&2; fail "phase 9d: the zero case lost its distinct wording"; }
note "harness side: counted(2)+recurrence+x2+honesty-limit / absent(UNKNOWN-not-zero) / torn(floor) / zero(FIRST) — verdict unchanged in all four"

# 9e — the VERB surface: the same four states through the model's own tool.
# FAILS if fx_outcome does not surface the journal at all (the seat written
# and called by nobody), or if any state's wording collides with another's.
VV="$TMP/vroot"
mkdir -p "$VV/fx/disk/store/.db/snapshots" || fail "phase 9e: cannot lay out the verb root"
printf '9\n' > "$VV/fx/disk/store/.db/snapshots/CURRENT"
printf '8 in-progress 1700000000\n8 failed 1700000020\n' > "$VV/fx/disk/store/.bootlog"
outverb() { # outverb BIN ROOT -> the fx_outcome reply text on stdout
    FX_VERB_ROOT="$2" python3 - "$1" <<'PYEOF' || fail "phase 9e: outverb driver failed"
import json, subprocess, sys
srv = subprocess.Popen([sys.argv[1]], stdin=subprocess.PIPE,
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
def req(obj):
    srv.stdin.write((json.dumps(obj) + "\n").encode()); srv.stdin.flush()
    return srv.stdout.readline().decode()
req({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
srv.stdin.write((json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}}) + "\n").encode()); srv.stdin.flush()
d = json.loads(req({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                    "params": {"name": "fx_outcome", "arguments": {}}}))
srv.stdin.close(); srv.wait(timeout=5)
sys.stdout.write(d["result"]["content"][0]["text"])
PYEOF
}
# 9e-1: the full journal (count, last, recurrence) — the model's own read
cat > "$VV/fx/disk/store/.recovery" <<'J1'
# fx-init recovery journal. One DATA line per AUTOMATIC roll-forward:
# line: <epoch-s> <published-version> <from-failed-version> <content-genhash|->
1791556214 9 7 feedface0123456789abcdef
1791556300 11 9 feedface0123456789abcdef
1791556400 13 11 0123456789abcdef012345
J1
TXT=$(outverb "$VS" "$VV")
printf '%s\n' "$TXT" | grep -q "^exit=0$" || { printf '%s\n' "$TXT" >&2; fail "phase 9e-1: fx_outcome failed on a store with a journal"; }
printf '%s\n' "$TXT" | grep -q "^recoveries 3\$" \
    || { printf '%s\n' "$TXT" >&2; fail "phase 9e-1: the verb does not report the journal COUNT"; }
printf '%s\n' "$TXT" | grep -q "^recovery_last 1791556400 published v13 from v11 genhash 0123456789abcdef012345\$" \
    || { printf '%s\n' "$TXT" >&2; fail "phase 9e-1: the verb does not report the LAST recovery verbatim"; }
printf '%s\n' "$TXT" | grep -q "^recovery_recur feedface0123456789abcdef x2 — the SAME fault returning" \
    || { printf '%s\n' "$TXT" >&2; fail "phase 9e-1: the verb does not report the recurring genhash"; }
printf '%s\n' "$TXT" | grep -q "boot 8 failed" \
    || { printf '%s\n' "$TXT" >&2; fail "phase 9e-1: the bootlog history was displaced by the journal section"; }
# 9e-2: ABSENT — the distinct wording, not a zero
rm -f "$VV/fx/disk/store/.recovery"
TXT=$(outverb "$VS" "$VV")
printf '%s\n' "$TXT" | grep -q "^exit=0\$" || { printf '%s\n' "$TXT" >&2; fail "phase 9e-2: an absent journal made the verb fail"; }
printf '%s\n' "$TXT" | grep -q "^recovery absent (no .recovery" \
    || { printf '%s\n' "$TXT" >&2; fail "phase 9e-2: the verb does not report the journal as ABSENT"; }
printf '%s\n' "$TXT" | grep -q "unknown, not zero" \
    || { printf '%s\n' "$TXT" >&2; fail "phase 9e-2: absent is not worded as distinct from zero"; }
printf '%s\n' "$TXT" | grep -qE "^recoveries " \
    && { printf '%s\n' "$TXT" >&2; fail "phase 9e-2: an absent journal produced a COUNT line"; }
# 9e-3: present, never recovered — the zero with its own words
printf '# fx-init recovery journal. One DATA line per AUTOMATIC roll-forward:\n' > "$VV/fx/disk/store/.recovery"
TXT=$(outverb "$VS" "$VV")
printf '%s\n' "$TXT" | grep -q "^recoveries 0 (journal present; no automatic roll-forward recorded)\$" \
    || { printf '%s\n' "$TXT" >&2; fail "phase 9e-3: a never-recovered journal does not read as the distinct ZERO state"; }
# 9e-4: two '-' genhashes are two ABSENCES, not a recurrence — the honest
# reading of the writer's own '-' (unresolvable) marker.  FAILS if the reader
# matches absent hashes and claims "the same fault returning" from no evidence.
printf '1791556214 9 7 -\n1791556300 11 9 -\n' > "$VV/fx/disk/store/.recovery"
TXT=$(outverb "$VS" "$VV")
printf '%s\n' "$TXT" | grep -q "^recoveries 2\$" \
    || { printf '%s\n' "$TXT" >&2; fail "phase 9e-4: the '-' lines are not counted"; }
printf '%s\n' "$TXT" | grep -q "recovery_recur" \
    && { printf '%s\n' "$TXT" >&2; fail "phase 9e-4: two '-' genhashes read as a RECURRENCE — an inference beyond the evidence"; }
# 9e-5: the torn tail through the verb — the floor, said
{ printf '1791556214 9 7 feedface0123456789abcdef\n'; printf '%s' "1791556300 11 9 feedfa"; } > "$VV/fx/disk/store/.recovery"
TXT=$(outverb "$VS" "$VV")
printf '%s\n' "$TXT" | grep -q "^recoveries 1\$" \
    || { printf '%s\n' "$TXT" >&2; fail "phase 9e-5: the torn line changed the count (want exactly the 1 complete line)"; }
printf '%s\n' "$TXT" | grep -q "^recovery_torn 1 line(s) skipped" \
    || { printf '%s\n' "$TXT" >&2; fail "phase 9e-5: the torn line is not reported as skipped"; }
note "verb side: recoveries N / recovery_last / recovery_recur / absent / zero / '-'-is-not-recurrence / torn-floor"

# 9f — ASYMMETRY against the PINNED pre-read server (d94ea77: the last tree
# before this change — its fx_outcome ignores .recovery entirely, which is
# exactly the seat-written-and-never-called state this phase closes).  The pin
# is a FIXED revision, cat-file guarded, and cmp-proven to DIFFER from the
# working tree, so the arm can never compare the code to itself.
PIN_NOREC="d94ea77"
NOREC86=""
git -C "$ROOT" cat-file -e "$PIN_NOREC^{commit}" 2>/dev/null \
    || NOREC86="revision $PIN_NOREC unavailable (shallow clone or rewritten history)"
mkdir -p "$TMP/norec/tools" "$TMP/norec/llm2" || fail "phase 9f: cannot create the pinned source dir"
if [ -z "$NOREC86" ]; then
    # the include is "llm2/outcome.h", so src/llm2/* lands at $TMP/norec/llm2/*
    git -C "$ROOT" show "$PIN_NOREC:tools/fx-verbs-server.c" > "$TMP/norec/tools/fx-verbs-server.c" 2>/dev/null \
        || NOREC86="cannot extract tools/fx-verbs-server.c at $PIN_NOREC"
    git -C "$ROOT" show "$PIN_NOREC:src/llm2/outcome.c" > "$TMP/norec/llm2/outcome.c" 2>/dev/null \
        || NOREC86="cannot extract src/llm2/outcome.c at $PIN_NOREC"
    git -C "$ROOT" show "$PIN_NOREC:src/llm2/outcome.h" > "$TMP/norec/llm2/outcome.h" 2>/dev/null \
        || NOREC86="cannot extract src/llm2/outcome.h at $PIN_NOREC"
    # DOMAIN PROOF: the pin must differ from the working tree in the file that
    # carries the read (identical outcome.c would mean the arm compiles the
    # fix against the old server, or the fix was reverted).
    [ -z "$NOREC86" ] && cmp -s "$TMP/norec/llm2/outcome.c" "$ROOT/src/llm2/outcome.c" \
        && NOREC86="the pinned $PIN_NOREC outcome.c is IDENTICAL to the working tree — the pre-read arm would compare the code to itself"
    [ -z "$NOREC86" ] && cmp -s "$TMP/norec/tools/fx-verbs-server.c" "$ROOT/tools/fx-verbs-server.c" \
        && NOREC86="the pinned $PIN_NOREC fx-verbs-server.c is IDENTICAL to the working tree"
fi
if [ -n "$NOREC86" ]; then
    echo "SKIP outcome: phase 9f (pre-read arm): $NOREC86"
else
cc -std=c11 -O2 -Wall -Wextra -I"$TMP/norec" -I"$ROOT/src/vendor/yyjson" \
   -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE \
   -o "$TMP/vs-norec" "$TMP/norec/tools/fx-verbs-server.c" \
   "$TMP/norec/llm2/outcome.c" "$ROOT/src/vendor/yyjson/yyjson.c" \
   || fail "phase 9f: cannot build the pinned $PIN_NOREC fx-verbs-server"
cat > "$VV/fx/disk/store/.recovery" <<'J2'
# fx-init recovery journal. One DATA line per AUTOMATIC roll-forward:
1791556214 9 7 feedface0123456789abcdef
1791556300 11 9 feedface0123456789abcdef
J2
TXT=$(outverb "$TMP/vs-norec" "$VV")
printf '%s\n' "$TXT" | grep -q "^exit=0\$" \
    || { printf '%s\n' "$TXT" >&2; fail "phase 9f: the pinned server failed on a store WITH a journal (arm is vacuous)"; }
printf '%s\n' "$TXT" | grep -qE "^recover(y|ies)" \
    && { printf '%s\n' "$TXT" >&2; fail "phase 9f: the pinned $PIN_NOREC server SURFACED the journal — the pre-read arm proves nothing (was the read reverted?)"; }
printf '%s\n' "$TXT" | grep -q "boot 8 failed" \
    || { printf '%s\n' "$TXT" >&2; fail "phase 9f: the pinned server's fx_outcome is otherwise broken (arm is vacuous)"; }
# the REPORT side of the same asymmetry, behaviorally: the pinned outcome.c is
# what the pre-change harness binary was built from, so its ACTIVATION_FAILED
# report must refuse exactly like this tree's — same verdict — while carrying
# NO journal line.  (FAILS "prove nothing" if the pinned verdict differs: the
# arm would compare a refusal to a run.)
cat > "$TMP/recprobe9.c" <<'CEOF'
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <string.h>
#include "llm2/outcome.h"
int main(int argc, char **argv) {
    if (argc < 3) return 2;
    FxOutcome o;
    char rep[FX_OUTCOME_MSG_CAP * 2];   /* generous: we MEASURE the length */
    FxVerdict v = fx_outcome_verdict(argv[1], argv[2], argv[3], NULL,
                                     &o, rep, sizeof rep, NULL, 0);
    printf("verdict=%d len=%zu hasjournal=%d\n", (int)v, strlen(rep),
           strstr(rep, "automatic roll-forward") != NULL);
    return 0;
}
CEOF
cc -std=c11 -O2 -Wall -Wextra -I"$TMP/norec" \
   -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE \
   -o "$TMP/recprobe9-pin" "$TMP/recprobe9.c" "$TMP/norec/llm2/outcome.c" \
   || fail "phase 9f: cannot build the report probe against the pinned $PIN_NOREC outcome.c"
cc -std=c11 -O2 -Wall -Wextra -I"$ROOT/src" -I"$ROOT/src/llm2" \
   -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE \
   -o "$TMP/recprobe9-fix" "$TMP/recprobe9.c" "$ROOT/src/llm2/outcome.c" \
   || fail "phase 9f: cannot build the report probe against this tree"
mkdir -p "$TMP/pin-data" || fail "phase 9f: cannot create the probe data dir"
printf '1700000000 %s attempt - - 0 /fx/disk/agent-config.dhall\n' "$TASK" > "$TMP/pin-data/attempts.jsonl"
printf '1700000000 %s result - - 8 /fx/disk/agent-config.dhall\n' "$TASK" >> "$TMP/pin-data/attempts.jsonl"
PINOUT=$("$TMP/recprobe9-pin" "$TMP/pin-data" "$TASK" "$VV/fx/disk/store") \
    || fail "phase 9f: the pinned report probe failed"
case "$PINOUT" in verdict=1\ *\ hasjournal=0) ;;
    *) fail "phase 9f: the pinned $PIN_NOREC report is not the plain ACTIVATION_FAILED refusal ('$PINOUT') — the before-direction is not the pre-read behaviour";;
esac
FIXOUT=$("$TMP/recprobe9-fix" "$TMP/pin-data" "$TASK" "$VV/fx/disk/store") \
    || fail "phase 9f: the fixed report probe failed"
case "$FIXOUT" in verdict=1\ *\ hasjournal=1) ;;
    *) fail "phase 9f: the fixed report probe did not carry the journal ('$FIXOUT')";;
esac
note "ASYMMETRY PROVEN: identical store WITH a journal — the pinned $PIN_NOREC fx_outcome prints no recovery line at all (the seat nobody called); this tree counts it"
fi

# 9g — a journal that EXISTS but cannot be READ is its OWN state: not ABSENT
# (there is no journal) and not ZERO (the journal is there and has counted
# nothing).  Both of those are claims about the file's CONTENT; this one is a
# claim about the READ, and reporting it as either would be reporting a
# measurement that was never made.  MEASURED, the collapse was REAL and silent
# before this arm existed — and it is the SECOND of the two cases this item
# names: glibc's fopen() SUCCEEDS on a DIRECTORY, the first fgets then fails
# with EISDIR, and the reader returned a count of 0, so a directory planted
# where the journal belongs read as "0 automatic roll-forwards on record …
# this is the FIRST time this machine has had to recover".  FAILS if the
# directory reads as ZERO or as ABSENT, if the state does not carry WHY, if it
# changes the verdict, or if the escape clause is lost from the report.
newdata
plant_store 9 "8 in-progress 1700000000" "8 failed 1700000020" "9 in-progress 1700000030"
rm -f "$STORE/.recovery"
mkdir "$STORE/.recovery" || fail "phase 9g: cannot plant a directory where the journal belongs"
record "1700000000 $TASK attempt - - 0 /fx/disk/agent-config.dhall"
record "1700000000 $TASK result - - 8 /fx/disk/agent-config.dhall"
out=$(run "$BIN" --store "$STORE"); rc=$?
[ "$rc" = 0 ] || fail "phase 9g: rc=$rc (an unreadable journal is information, not a service failure)"
echo "$out" | grep -q "THE ACTIVATION THIS HARNESS RECORDED FAILED" \
    || { echo "$out" >&2; fail "phase 9g: the verdict changed on an unreadable journal"; }
echo "$out" | grep -q "recovery : UNREADABLE" \
    || { echo "$out" >&2; fail "phase 9g: a journal that exists but cannot be read is not its own state"; }
echo "$out" | grep -q "cannot be read" \
    || { echo "$out" >&2; fail "phase 9g: the unreadable state does not carry WHY (the path and the errno)"; }
echo "$out" | grep -q "UNKNOWN, not zero" \
    || { echo "$out" >&2; fail "phase 9g: the unreadable state does not refuse the zero claim"; }
echo "$out" | grep -q "0 automatic roll-forwards" \
    && { echo "$out" >&2; fail "phase 9g: an UNREADABLE journal read as ZERO — a measurement that was never made"; }
echo "$out" | grep -q "no .recovery on this store" \
    && { echo "$out" >&2; fail "phase 9g: an UNREADABLE journal read as ABSENT — two distinct states collapsed"; }
assert_escape "phase 9g" "$out"
# the SAME state on the VERB surface (the model's own read) and the same
# distinctness there: FAILS if the verb drops the state, prints a count for a
# journal it could not read, or words it as absence.
rm -f "$VV/fx/disk/store/.recovery"
mkdir "$VV/fx/disk/store/.recovery" || fail "phase 9g: cannot plant the verb-side directory"
TXT=$(outverb "$VS" "$VV")
printf '%s\n' "$TXT" | grep -q "^exit=0\$" \
    || { printf '%s\n' "$TXT" >&2; fail "phase 9g: an unreadable journal made the verb fail (it is not fatal)"; }
printf '%s\n' "$TXT" | grep -q "^recovery UNREADABLE: " \
    || { printf '%s\n' "$TXT" >&2; fail "phase 9g: the verb does not report the unreadable journal as its own state"; }
printf '%s\n' "$TXT" | grep -qE "^recoveries " \
    && { printf '%s\n' "$TXT" >&2; fail "phase 9g: the verb printed a COUNT for a journal it could not read"; }
printf '%s\n' "$TXT" | grep -q "^recovery absent" \
    && { printf '%s\n' "$TXT" >&2; fail "phase 9g: the verb collapsed unreadable into absent"; }
# EACCES — the OTHER way in (fopen itself fails; the directory case above gets
# past fopen).  GATED ON A NON-ROOT uid: as root the mode bits are advisory and
# the arm would pass against a reader that never looked at errno — a test that
# cannot fail is not a test.
if [ "$(id -u)" != 0 ]; then
    rm -rf "$STORE/.recovery"
    plant_journal "1791556214 9 7 feedface0123456789abcdef"
    chmod 000 "$STORE/.recovery"
    out=$(run "$BIN" --store "$STORE"); rc=$?
    chmod 644 "$STORE/.recovery"
    [ "$rc" = 0 ] || fail "phase 9g: rc=$rc on an EACCES journal"
    echo "$out" | grep -q "recovery : UNREADABLE" \
        || { echo "$out" >&2; fail "phase 9g: a chmod-000 journal (fopen fails) is not reported as UNREADABLE"; }
    echo "$out" | grep -q "Permission denied" \
        || { echo "$out" >&2; fail "phase 9g: the EACCES case does not carry the errno that explains it"; }
    note "unreadable: EISDIR (a directory, which glibc fopen ACCEPTS) and EACCES both read as UNREADABLE — never absent, never zero"
else
    note "unreadable: EACCES arm SKIPPED (uid 0 — mode bits are advisory, the arm could not fail)"
fi

# ── phase 10: A CUT REPORT IS LOUD, AND THE CAP IS DERIVED, NOT ESTIMATED ═══
# WHY.  At the former 2048-byte cap the ACTIVATION_FAILED report was ALREADY
# truncated in the corner case (a 511-char config plus a 255-char session plus
# the recovery-journal line), and what the cut removed was the ESCAPE CLAUSE —
# the tail naming the task's ONLY way out (--reconsider, or removing the
# task's lines).  A refusal whose escape is silently missing is a permanent
# wedge, and nothing in the tree noticed; the cap was raised against an
# ESTIMATE.  Item 2 replaces the estimate with a derivation (outcome.h) and
# Item 1 makes the cut LOUD (outcome.c, report()).
# WHAT MAKES EACH ARM FAIL:
#   10a FAILS if the cap is too small for the field caps (the marker fires where
#       the whole report was supposed to fit), or if the probe's own record did
#       not round-trip at the caps (then it would be measuring a smaller case —
#       the premise is asserted, not assumed).
#   10b FAILS if report() cuts SILENTLY (no marker: the pre-fix behaviour), if
#       the marker is emitted twice, if it is not the LAST line (i.e. if the
#       marker itself was cut by the cut it describes), or if it names the wrong
#       byte count.
#   10c FAILS if the escape clause is not the thing a real cut eats — the
#       marker's own wording ("the escape clause may be missing") would then be
#       alarm without a measurement.  It is also the standing demonstration of
#       WHERE the next truncation comes from: an input with NO field cap.
#   10d FAILS if the pinned pre-fix outcome.c ALSO emits the marker — then 10b
#       would be comparing the fix to itself and could never have failed.
#   10e FAILS if the ESCAPE CLAUSE is cut by its own buffer while the report is
#       still under the cap — the one cut the marker cannot see — and it is
#       asymmetried against the pinned tree, which loses the tail there.
echo "== phase 10: the report's truncation marker + the derived cap (worst case at EXACTLY the field caps)"
MAXU=$(python3 -c 'print(2**64-1)')          # 20 decimal digits: the widest a %lu prints
LS=$(python3 -c 'print("s"*255)')            # a session is NAME_MAX wide
LR=$(python3 -c 'print("r"*63)')
LC=$(python3 -c 'print("c"*511)')            # FX_OUTCOME_PATH_CAP-1
LG=$(python3 -c 'print("f"*71)')             # FX_OUTCOME_GENHASH_CAP-1
newdata
plant_store "$MAXU" "$MAXU in-progress 1700000000" "$MAXU failed 1700000020"
plant_journal "$MAXU $MAXU $MAXU $LG" "$MAXU $MAXU $MAXU $LG"
python3 -c 'import sys; sys.stdout.write("1"*600)' >> "$STORE/.recovery"  # torn tail: a FLOOR, not a count
record "$MAXU $TASK attempt $LS $LR $MAXU $LC"
record "$MAXU $TASK result $LS $LR $MAXU $LC"
cat > "$TMP/capprobe.c" <<'CEOF'
/* The report's OWN worst case, straight at the API.  Three buffer sizes:
 * 8x the cap (the UNDISTORTED length), exactly the cap (what the harness's own
 * caller, src/llm2/agent_main.c, hands it) and 512 (a cap nothing in the tree
 * uses — the marker must fire for ANY cap that cuts, not just this one). */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <string.h>
#include "llm2/outcome.h"

static char big[FX_OUTCOME_MSG_CAP * 8], prod[FX_OUTCOME_MSG_CAP], smallbuf[512];

static size_t call(const char *d, const char *s, const char *t, const char *a,
                   char *buf, size_t cap) {
    FxOutcome o;
    fx_outcome_verdict(d, t, s, a, &o, buf, cap, NULL, 0);
    return strlen(buf);
}
static int count(const char *h, const char *n) {
    int c = 0;
    for (const char *p = h; (p = strstr(p, n)) != NULL; p += strlen(n)) c++;
    return c;
}
int main(int argc, char **argv) {
    if (argc < 4) return 2;
    const char *data = argv[1], *store = argv[2], *task = argv[3];
    const char *agent = argc > 4 ? argv[4] : "fx";
    FxOutcome o;
    size_t tlen = call(data, store, task, agent, big, sizeof big);
    size_t plen = call(data, store, task, agent, prod, sizeof prod);
    call(data, store, task, agent, smallbuf, sizeof smallbuf);
    /* built against this tree AND the pinned pre-fix sources (capprobe-pin):
     * the err-params signature arrived with FX_OUTCOME_ERR_CAP */
#ifdef FX_OUTCOME_ERR_CAP
    fx_outcome_record_load(data, task, &o, NULL, 0);
#else
    fx_outcome_record_load(data, task, &o);
#endif
    printf("cap=%d\nlen_true=%zu\nlen_cap=%zu\nmargin=%d\n", FX_OUTCOME_MSG_CAP,
           tlen, plen, FX_OUTCOME_MSG_CAP - (int)tlen);
    printf("marker_at_cap=%d\nmarker_count_at_cap=%d\nescape_at_cap=%d\n",
           strstr(prod, "... TRUNCATED at ") != NULL, count(prod, "... TRUNCATED at "),
           (strstr(prod, "--reconsider") != NULL) && (strstr(prod, "/attempts.jsonl") != NULL));
    printf("marker_at_small=%d\nmarker_count_at_small=%d\n",
           strstr(smallbuf, "... TRUNCATED at ") != NULL,
           count(smallbuf, "... TRUNCATED at "));
    /* THE PROBE'S OWN PREMISE, asserted by the caller: the record really did
     * round-trip at the field caps, so this is the worst case and not a
     * smaller one wearing its name. */
    printf("in_task=%zu\nin_session=%zu\nin_run=%zu\nin_config=%zu\n",
           strlen(o.task), strlen(o.session), strlen(o.run), strlen(o.config));
    printf("shape_data=%zu\nshape_store=%zu\nshape_agent=%zu\n",
           strlen(data), strlen(store), strlen(agent));
    printf("---small---\n%s\n---end---\n", smallbuf);
    return 0;
}
CEOF
cc -std=c11 -O2 -Wall -Wextra -I"$ROOT/src" -I"$ROOT/src/llm2" \
   -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE \
   -o "$TMP/capprobe" "$TMP/capprobe.c" "$ROOT/src/llm2/outcome.c" \
   || fail "phase 10: cannot build the cap probe"
MINDIR="$TMP/data"
MINSTORE="$STORE"
P=$("$TMP/capprobe" "$MINDIR" "$MINSTORE" "$TASK" fx) || fail "phase 10: the cap probe failed"
gv() { printf '%s\n' "$P" | sed -n "s/^$1=//p"; }
# 10a — the premise, then the worst case at the caps
[ "$(gv in_task)" = 16 ] && [ "$(gv in_session)" = 255 ] && [ "$(gv in_run)" = 63 ] \
    && [ "$(gv in_config)" = 511 ] \
    || { printf '%s\n' "$P" >&2; fail "phase 10: the probe's record did NOT round-trip at the field caps (task $(gv in_task)/16, session $(gv in_session)/255, run $(gv in_run)/63, config $(gv in_config)/511) — a smaller case is wearing the worst case's name"; }
CAP=$(gv cap)
LEN=$(gv len_true)
[ "$LEN" -lt "$CAP" ] \
    || { printf '%s\n' "$P" >&2; fail "phase 10: the field-cap worst case is $LEN bytes and the cap is $CAP — RAISE FX_OUTCOME_MSG_CAP"; }
[ "$(gv marker_at_cap)" = 0 ] \
    || { printf '%s\n' "$P" >&2; fail "phase 10: the truncation marker fired AT the field caps — the report does not fit the cap it is built into"; }
[ "$(gv escape_at_cap)" = 1 ] \
    || { printf '%s\n' "$P" >&2; fail "phase 10: the ESCAPE CLAUSE is not intact at the field caps"; }
note "worst case at the field caps (task 16, session 255, run 63, config 511, genhash 71, 20-digit versions): $LEN bytes of $CAP (margin $(gv margin)); data dir $(gv shape_data) B, store $(gv shape_store) B — the derivation in outcome.h reproduces this shape to the byte"
# 10b — THE MARKER APPEARS, exactly once, AS THE LAST LINE, naming the true count
[ "$(gv marker_at_small)" = 1 ] \
    || { printf '%s\n' "$P" >&2; fail "phase 10: a report cut at a 512-byte cap carries NO truncation marker — the cut is silent (the pre-fix behaviour)"; }
[ "$(gv marker_count_at_small)" = 1 ] \
    || { printf '%s\n' "$P" >&2; fail "phase 10: the marker was emitted $(gv marker_count_at_small) times (want exactly 1)"; }
SMALL_TAIL=$(printf '%s\n' "$P" | sed -n '/^---small---$/,/^---end---$/p' | sed '1d;$d' | sed -n '/./p' | tail -1)
WANT_TAIL="... TRUNCATED at $LEN bytes — the escape clause may be missing; raise FX_OUTCOME_MSG_CAP"
[ "$SMALL_TAIL" = "$WANT_TAIL" ] \
    || { printf '%s\n' "$SMALL_TAIL" >&2; fail "phase 10: the last line of the cut report is not the marker verbatim (want '$WANT_TAIL') — the marker is itself cut, or names the wrong byte count"; }
[ "$(gv len_cap)" = "$LEN" ] \
    || fail "phase 10: the report built into the cap is $(gv len_cap) bytes but the undistorted report is $LEN — the field-cap worst case does NOT fit FX_OUTCOME_MSG_CAP"
# 10c — WHERE THE NEXT TRUNCATION COMES FROM: an input with NO field cap.  A
# path ~267 bytes longer than $TMP (a deep VIBE_RUNTIME_DIR / store) is counted
# TWICE in the report (its own line, and the escape clause), and it takes the
# whole ESCAPE CLAUSE out — the marker is then the only thing standing between
# the reader and a wedge.
DEEP="$TMP/deep/$(python3 -c 'print("d"*200)')/$(python3 -c 'print("e"*60)')"
mkdir -p "$DEEP/data" "$DEEP/store/.db/snapshots" || fail "phase 10: cannot lay out the deep path"
cp "$TMP/data/attempts.jsonl" "$DEEP/data/"
cp "$STORE/.bootlog" "$DEEP/store/"
cp "$STORE/.db/snapshots/CURRENT" "$DEEP/store/.db/snapshots/"
cp "$STORE/.recovery" "$DEEP/store/"
PL=$("$TMP/capprobe" "$DEEP/data" "$DEEP/store" "$TASK" fx) || fail "phase 10: the deep-path probe failed"
gp() { printf '%s\n' "$PL" | sed -n "s/^$1=//p"; }
[ "$(gp len_true)" -gt "$CAP" ] \
    || { printf '%s\n' "$PL" >&2; fail "phase 10: a $(( $(gp shape_data) )) B data dir did NOT push the report past the cap ($(gp len_true) <= $CAP) — this arm proves nothing"; }
[ "$(gp marker_at_cap)" = 1 ] \
    || { printf '%s\n' "$PL" >&2; fail "phase 10: a report that does NOT fit the cap was printed WITHOUT the marker — the wedge is silent"; }
[ "$(gp marker_count_at_cap)" = 1 ] \
    || { printf '%s\n' "$PL" >&2; fail "phase 10: the marker was emitted $(gp marker_count_at_cap) times (want exactly 1)"; }
[ "$(gp escape_at_cap)" = 0 ] \
    || { printf '%s\n' "$PL" >&2; fail "phase 10: the cut did NOT reach the escape clause — 'the escape clause may be missing' would be alarm without a measurement"; }
[ "$(gp in_config)" = 511 ] && [ "$(gp in_session)" = 255 ] \
    || { printf '%s\n' "$PL" >&2; fail "phase 10: the deep-path arm is not at the field caps — the marker could be firing for the wrong reason"; }
note "over cap: data dir $(( $(gp shape_data) )) B + store $(( $(gp shape_store) )) B -> $(gp len_true) B, cut to $((CAP - 1)), marker present, and the ESCAPE CLAUSE is gone (--reconsider absent) — LOUD, not wedged"
# 10d — THE ASYMMETRY: the pinned pre-marker outcome.c cuts the same report the
# same way and says NOTHING, so 10b could have failed before this change.  The
# pin is a FIXED revision, cat-file guarded, and cmp-proven to differ.
if [ -z "$NOREC86" ]; then
    cc -std=c11 -O2 -Wall -Wextra -I"$TMP/norec" \
       -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE \
       -o "$TMP/capprobe-pin" "$TMP/capprobe.c" "$TMP/norec/llm2/outcome.c" \
       || fail "phase 10: cannot build the cap probe against the pinned $PIN_NOREC outcome.c"
    cmp -s "$TMP/norec/llm2/outcome.c" "$ROOT/src/llm2/outcome.c" \
        && fail "phase 10: the pinned $PIN_NOREC outcome.c is IDENTICAL to the working tree — the arm would compare the fix to itself"
    PP=$("$TMP/capprobe-pin" "$MINDIR" "$MINSTORE" "$TASK" fx) \
        || fail "phase 10: the pinned cap probe failed (arm is vacuous)"
    PP_CAP=$(printf '%s\n' "$PP" | sed -n 's/^cap=//p')
    PP_LEN=$(printf '%s\n' "$PP" | sed -n 's/^len_true=//p')
    PP_FILL=$(printf '%s\n' "$PP" | sed -n 's/^len_cap=//p')
    # The pinned tree predates the JOURNAL READ, so its report is the shorter
    # pre-journal one — stated here rather than papered over.  What matters is
    # that its report is STILL over its own cap at these field caps: that is the
    # headline defect reproduced independently, and the cut says nothing.
    [ "$PP_LEN" -gt "$PP_CAP" ] \
        || { printf '%s\n' "$PP" >&2; fail "phase 10: the pinned $PIN_NOREC report is $PP_LEN bytes and fits its own ${PP_CAP}-byte cap — the defect this phase is about does not reproduce there, so the arm is vacuous"; }
    printf '%s\n' "$PP" | grep -q "^len_cap=$((PP_CAP - 1))$" \
        || { printf '%s\n' "$PP" >&2; fail "phase 10: the pinned report did not fill its buffer at the cap (fill $PP_FILL, want $((PP_CAP - 1))) — there is no cut for the marker to miss"; }
    printf '%s\n' "$PP" | grep -q "^marker_at_cap=0$" \
        || { printf '%s\n' "$PP" >&2; fail "phase 10: the pinned $PIN_NOREC report carries the marker — 10b never could have failed, so it is not a guard"; }
    printf '%s\n' "$PP" | grep -q "^marker_at_small=0$" \
        || { printf '%s\n' "$PP" >&2; fail "phase 10: the pinned $PIN_NOREC report carries the marker at the 512-byte cap as well"; }
    note "ASYMMETRY PROVEN: the pinned $PIN_NOREC outcome.c builds a $PP_LEN-byte ACTIVATION_FAILED report (pre-journal) against its 2048-byte cap and CUTS it to $PP_FILL with NO marker — the silent truncation this phase closes; this tree's $LEN-byte report fits $CAP and, when it does not, says so"
else
    note "phase 10: marker asymmetry SKIPPED ($NOREC86)"
fi
# 10e — THE ESCAPE CLAUSE'S OWN BUFFER, asserted on its own.  The marker catches
# a report that overruns FX_OUTCOME_MSG_CAP, but a snprintf into a too-small
# `escape` buffer cuts the clause SILENTLY while the whole report stays UNDER the
# cap — the marker never fires, and the cut lands exactly where it hurts (the
# tail of that clause names attempts.jsonl, the way out).  The buffer was
# FX_OUTCOME_PATH_CAP+320 = 832 bytes, so a data dir over ~600 characters lost
# its tail; it is PATH_MAX+320 now.  FAILS if any part of the clause is missing
# at a data dir length the report can still be built for, or if the data dir
# does not survive verbatim — and it asserts marker=0 first, so a marker firing
# here could not be mistaken for the clause being intact.
echo "== phase 10e: the escape clause is not cut in the clause's OWN buffer"
D2="$DEEP/$(python3 -c 'print("g"*200)')/$(python3 -c 'print("h"*200)')/data"
mkdir -p "$D2" || fail "phase 10e: cannot lay out the deep data dir"
printf '1700000000 %s done - - 0 -\n' "$TASK" > "$D2/attempts.jsonl" \
    || fail "phase 10e: cannot plant a completed-task record"
cat > "$TMP/escprobe.c" <<'CEOF'
/* The ALREADY_DONE report (the smallest of the nine) with a long data dir: the
 * whole report stays under the cap, so the ONLY thing that can cut the escape
 * clause here is the clause's own buffer. */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <string.h>
#include "llm2/outcome.h"
static char rep[FX_OUTCOME_MSG_CAP * 8];
int main(int argc, char **argv) {
    if (argc < 3) return 2;
    FxOutcome o;
    FxVerdict v = fx_outcome_verdict(argv[1], argv[2], NULL, "fx", &o, rep,
                                     sizeof rep, NULL, 0);
    printf("verdict=%d\nlen=%zu\ncap=%d\nmarker=%d\n", (int)v, strlen(rep),
           FX_OUTCOME_MSG_CAP, strstr(rep, "... TRUNCATED at ") != NULL);
    printf("---tail---\n%s\n---end---\n", rep);
    return 0;
}
CEOF
cc -std=c11 -O2 -Wall -Wextra -I"$ROOT/src" -I"$ROOT/src/llm2" \
   -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE \
   -o "$TMP/escprobe" "$TMP/escprobe.c" "$ROOT/src/llm2/outcome.c" \
   || fail "phase 10e: cannot build the escape-clause probe"
D2LEN=${#D2}
[ "$D2LEN" -gt 600 ] || fail "phase 10e: the deep data dir is only $D2LEN characters — it would not have cut the pre-fix clause, so the arm proves nothing"
E=$("$TMP/escprobe" "$D2" "$TASK") || fail "phase 10e: the escape-clause probe failed"
ge() { printf '%s\n' "$E" | sed -n "s/^$1=//p"; }
[ "$(ge verdict)" = 2 ] || { printf '%s\n' "$E" >&2; fail "phase 10e: verdict $(ge verdict) (want 2, ALREADY_DONE) — the arm is not on the report it means to test"; }
[ "$(ge marker)" = 0 ] || { printf '%s\n' "$E" >&2; fail "phase 10e: the report is over the cap, so the cut is the marker's, not the clause's own buffer's — the arm proves nothing"; }
[ "$(ge len)" -lt "$(ge cap)" ] || { printf '%s\n' "$E" >&2; fail "phase 10e: the report does not fit the cap"; }
E_TAIL=$(printf '%s\n' "$E" | sed -n '/^---tail---$/,/^---end---$/p' | sed '1d;$d' | sed -n '/./p' | tail -1)
[ "$E_TAIL" = "             task's lines from $D2/attempts.jsonl" ] \
    || { printf '%s\n' "$E_TAIL" >&2; fail "phase 10e: the escape clause is CUT (the report is under the cap, so nothing else could have done it) — want the full '... from $D2/attempts.jsonl'"; }
note "escape clause intact at a $D2LEN-character data dir inside a $(ge len)-byte report (under the $(ge cap) cap, no marker): the clause's own buffer, not the report cap, is what keeps the way out readable"
# the asymmetry, so this arm could have failed: the PINNED tree builds the same
# clause into its own 832-byte buffer and loses the tail.
if [ -z "$NOREC86" ]; then
    cc -std=c11 -O2 -Wall -Wextra -I"$TMP/norec" \
       -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE \
       -o "$TMP/escprobe-pin" "$TMP/escprobe.c" "$TMP/norec/llm2/outcome.c" \
       || fail "phase 10e: cannot build the escape-clause probe against the pinned $PIN_NOREC outcome.c"
    PE=$("$TMP/escprobe-pin" "$D2" "$TASK") || fail "phase 10e: the pinned escape-clause probe failed"
    PE_TAIL=$(printf '%s\n' "$PE" | sed -n '/^---tail---$/,/^---end---$/p' | sed '1d;$d' | sed -n '/./p' | tail -1)
    [ "$PE_TAIL" != "$E_TAIL" ] \
        || { printf '%s\n' "$PE" >&2; fail "phase 10e: the pinned $PIN_NOREC tree's clause is INTACT too — the arm proves nothing"; }
    note "ASYMMETRY PROVEN: the pinned $PIN_NOREC tree cuts this clause at a $D2LEN-character data dir ('$PE_TAIL'); this tree keeps all of it"
else
    note "phase 10e: clause asymmetry SKIPPED ($NOREC86)"
fi

# ── phase 11: AN UNREADABLE BOOTLOG IS NOT "NO VERDICT LINE" ═══════════════
# THE DEFECT THIS PHASE CLOSES (todo.md's own entry, MEASURED by
# handoff-loud-truncation and re-measured on this tree before the fix): with a
# DIRECTORY at <store>/.bootlog (glibc fopen ACCEPTS a directory; the first
# read then fails EISDIR — a read error, not an empty file) and CURRENT == the
# activated generation, fx_outcome_verdict returned RUN, where a readable
# bootlog carrying the failure line returns ACTIVATION_FAILED.  RUN re-issues
# the activation; the bootlog is how the loop LEARNS its activation failed,
# and a read error is the ABSENCE OF EVIDENCE, never evidence of nothing.
# Every sub-phase names what makes it FAIL.
echo "== phase 11: an unreadable .bootlog is FX_VERDICT_ERROR naming the path — never RUN"
# 11a — THE MEASURED CELL: directory at .bootlog, CURRENT == activated, an
# accounted activation on record.  FAILS (as the original defect did) if the
# run PROCEEDS (rc=0, the marker on stdout = the task re-ran = the blind
# re-apply), or if the refusal does not name the PATH and the errno, or if it
# is not LOUD (anything but exit 2 would be deciding on a store it cannot
# read).
newdata
plant_store 8 "8 in-progress 1700000000"
rm -f "$STORE/.bootlog"
mkdir "$STORE/.bootlog" || fail "phase 11a: cannot plant a directory where the bootlog belongs"
record "1700000000 $TASK attempt - - 0 /fx/disk/agent-config.dhall"
record "1700000000 $TASK result - - 8 /fx/disk/agent-config.dhall"
out=$(run "$BIN" --store "$STORE"); rc=$?
[ "$rc" = 2 ] || { echo "out=$out"; cat "$TMP/err" >&2; fail "phase 11a: rc=$rc (want 2 — an unreadable bootlog must FAIL LOUDLY, not decide; rc=0 with the marker would be the defect: the task re-ran)"; }
case "$out" in *"$MARKER"*) fail "phase 11a: the task RAN off an unreadable bootlog — the re-issuing direction";; esac
grep -q "observation loop" "$TMP/err" || { cat "$TMP/err" >&2; fail "phase 11a: the refusal is not attributed to the observation loop"; }
grep -q "\.bootlog: cannot be read: Is a directory" "$TMP/err" \
    || { cat "$TMP/err" >&2; fail "phase 11a: the refusal does not name the path and the errno"; }
grep -q "the store is never guessed" "$TMP/err" \
    || { cat "$TMP/err" >&2; fail "phase 11a: the refusal does not carry the store rule's own words"; }
# 11b — THE CONTROL, the cell the MEASUREMENT compared against: the SAME store
# shape with a READABLE bootlog carrying the failure line is still (verbatim)
# ACTIVATION_FAILED.  FAILS if the new guard over-refuses — a readable failed
# bootlog must never become an error — or if the verdict itself changed.
newdata
plant_store 8 "8 in-progress 1700000000" "8 failed 1700000020"
record "1700000000 $TASK attempt - - 0 /fx/disk/agent-config.dhall"
record "1700000000 $TASK result - - 8 /fx/disk/agent-config.dhall"
out=$(run "$BIN" --store "$STORE"); rc=$?
[ "$rc" = 0 ] || { cat "$TMP/err" >&2; fail "phase 11b: rc=$rc (want 0 — a READABLE failed bootlog is the ordinary refusal)"; }
echo "$out" | grep -q "THE ACTIVATION THIS HARNESS RECORDED FAILED" \
    || { echo "$out" >&2; fail "phase 11b: the readable-control verdict changed (over-refusal: the guard must fire on the READ, not on the store shape)"; }
assert_escape "phase 11b" "$out"
# 11c — EACCES, the OTHER way in (fopen itself fails; the directory case gets
# past fopen).  GATED ON A NON-ROOT uid: as root the mode bits are advisory
# and the arm would pass against a reader that never looked at errno.
if [ "$(id -u)" != 0 ]; then
    chmod 000 "$STORE/.bootlog"
    out=$(run "$BIN" --store "$STORE"); rc=$?
    chmod 644 "$STORE/.bootlog"
    [ "$rc" = 2 ] || fail "phase 11c: rc=$rc on an EACCES bootlog (want 2)"
    grep -q "\.bootlog: cannot be opened: Permission denied" "$TMP/err" \
        || { cat "$TMP/err" >&2; fail "phase 11c: the EACCES case does not carry the errno that explains it"; }
else
    note "phase 11c: EACCES arm SKIPPED (uid 0 — mode bits are advisory, the arm could not fail)"
fi
# 11d — ABSENT bootlog (ENOENT): SILENCE, not an error — the journal's
# absent-is-a-state rule, and phase 5g's planted no-bootlog store already
# gates the done-in-force cell (ALREADY_DONE).  A store that predates
# .bootlog judges NOTHING, so its silence about any generation is true of the
# store, and the ordinary re-run proceeds.  This arm pins that DECISION (and
# its residual: a REMOVED bootlog also reads as silence — indistinguishable
# from a pre-bootlog store from this seat, and reachable only by a host-side
# actor; the model's write surface is closed to .bootlog).  FAILS if absence
# becomes an error (the pre-bootlog store would be wedged forever with no
# escape short of touching the file) or if it stops being silence.
newdata
plant_store 8
rm -f "$STORE/.bootlog"
record "1700000000 $TASK attempt - - 0 /fx/disk/agent-config.dhall"
record "1700000000 $TASK result - - 8 /fx/disk/agent-config.dhall"
out=$(run "$BIN" --store "$STORE"); rc=$?
[ "$rc" = 0 ] || { cat "$TMP/err" >&2; fail "phase 11d: rc=$rc (want 0 — an absent bootlog is silence; a pre-bootlog store must keep its ordinary re-runs)"; }
case "$out" in *"$MARKER"*) ;; *) echo "out=$out"; fail "phase 11d: the task did not run off an absent (silent) bootlog — absence is not a read error";; esac
note "absent bootlog: SILENCE (the ordinary rows) — distinct from the directory/EACCES refusals above"
# 11d-2 — THE EXEMPTION: done in force at C==A decides on the RECORD's own
# positive evidence, so even a bootlog that exists but CANNOT BE READ must not
# wedge a completed task (the damage rule's own "a done is not poisoned"
# reasoning, extended to the store's file).  FAILS if the unreadable bootlog
# errors here (over-refusal wedging a completed task) — and the readable
# counterpart (absent/done) is phase 5g's done-first-result arm.
newdata
plant_store 8 "8 in-progress 1700000000"
rm -f "$STORE/.bootlog"
mkdir "$STORE/.bootlog" || fail "phase 11d-2: cannot plant the directory"
record "1700000000 $TASK attempt - - 0 /fx/disk/agent-config.dhall"
record "1700000000 $TASK result - - 8 /fx/disk/agent-config.dhall"
record "1700000025 $TASK done - - 0 -"
out=$(run "$BIN" --store "$STORE"); rc=$?
[ "$rc" = 0 ] || { cat "$TMP/err" >&2; fail "phase 11d-2: rc=$rc (want 0 — a done in force is positive record evidence; an unreadable bootlog must not wedge a completed task)"; }
echo "$out" | grep -q "TASK ALREADY COMPLETE" \
    || { echo "$out" >&2; fail "phase 11d-2: the done-in-force verdict changed under an unreadable bootlog"; }
assert_escape "phase 11d-2" "$out"
# 11e — THE BOOTLOG'S OWN DAMAGE RULE: a TORN LAST LINE naming the activated
# generation must not license the ordinary re-run (its silence about v8 is a
# mid-write hole, not a judgement — the record's damage rule, applied to the
# store's file).  FAILS if the task runs (the torn "8 fail" read as no-verdict
# + C==A = RUN = the re-issuing direction), or if the stop is silent about
# WHY (an operator must be able to tell a torn bootlog from a supersession).
newdata
plant_store 8 "8 in-progress 1700000000"
printf '%s' "8 fail" >> "$STORE/.bootlog"     # torn: no newline
record "1700000000 $TASK attempt - - 0 /fx/disk/agent-config.dhall"
record "1700000000 $TASK result - - 8 /fx/disk/agent-config.dhall"
out=$(run "$BIN" --store "$STORE"); rc=$?
[ "$rc" = 0 ] || { cat "$TMP/err" >&2; fail "phase 11e: rc=$rc (want 0 — a torn bootlog is a STOP, not a service failure)"; }
case "$out" in *"$MARKER"*) fail "phase 11e: the task RAN off a torn bootlog naming its generation";; esac
echo "$out" | grep -q "THE STORE'S BOOTLOG IS DAMAGED" \
    || { echo "$out" >&2; fail "phase 11e: a torn tail naming the activated generation is not its own loud state"; }
echo "$out" | grep -q "UNTERMINATED" \
    || { echo "$out" >&2; fail "phase 11e: the report does not say the line is torn"; }
assert_escape "phase 11e" "$out"
# 11f — the same torn tail with C != A: the UNRESOLVED report must not claim
# "superseded before it ever booted" off a bootlog that was mid-write ABOUT
# MY GENERATION.  FAILS if the old unqualified claim stands (a false claim in
# a stop report is still false), or if the verdict changes.
newdata
plant_store 9 "8 in-progress 1700000000"
printf '%s' "8 fail" >> "$STORE/.bootlog"
record "1700000000 $TASK attempt - - 0 /fx/disk/agent-config.dhall"
record "1700000000 $TASK result - - 8 /fx/disk/agent-config.dhall"
out=$(run "$BIN" --store "$STORE"); rc=$?
[ "$rc" = 0 ] || fail "phase 11f: rc=$rc"
echo "$out" | grep -q "THE STORE CANNOT ACCOUNT FOR MY ACTIVATION" \
    || { echo "$out" >&2; fail "phase 11f: the verdict changed on a torn tail (still UNRESOLVED — a stop)"; }
echo "$out" | grep -q "is UNKNOWN" \
    || { echo "$out" >&2; fail "phase 11f: whether my generation was judged is not said UNKNOWN off a torn tail naming it"; }
echo "$out" | grep -q "superseded before it ever booted" \
    && { echo "$out" >&2; fail "phase 11f: the unqualified supersession claim stands over a torn tail naming my generation"; }
# 11g — THE SCOPE of the poison: a torn tail naming ANOTHER generation (5)
# does not poison mine — cross-version poisoning would wedge unrelated
# activations forever, the same bound the record's damage rule draws around
# tasks.  FAILS if the plain (correct) supersession wording disappears.
newdata
plant_store 9 "8 in-progress 1700000000"
printf '%s' "5 fai" >> "$STORE/.bootlog"
record "1700000000 $TASK attempt - - 0 /fx/disk/agent-config.dhall"
record "1700000000 $TASK result - - 8 /fx/disk/agent-config.dhall"
out=$(run "$BIN" --store "$STORE"); rc=$?
[ "$rc" = 0 ] || fail "phase 11g: rc=$rc"
echo "$out" | grep -q "superseded before it ever booted" \
    || { echo "$out" >&2; fail "phase 11g: a torn tail naming ANOTHER version poisoned mine — the damage rule is unscoped"; }
note "bootlog damage rule: torn-names-mine refuses RUN and says UNKNOWN at C!=A; torn-names-other changes nothing"
# 11h — THE RECORD'S OWN UNREADABLE STATE (the sweep found it in the same
# class): a directory where attempts.jsonl belongs is not "no record on
# file" — the no-record row is what RUN is issued on, and phase 0's ordinary
# first boot (ABSENT record -> RUN) is its control and stays green.  FAILS if
# the run proceeds off a record it never read (rc=0 = the blind re-apply), or
# if the refusal does not name the record path.
newdata
plant_store 9 "8 in-progress 1700000000" "8 failed 1700000020"
rm -f "$TMP/data/attempts.jsonl"
mkdir "$TMP/data/attempts.jsonl" || fail "phase 11h: cannot plant a directory where the record belongs"
out=$(run "$BIN" --store "$STORE"); rc=$?
[ "$rc" = 2 ] || { echo "out=$out"; fail "phase 11h: rc=$rc (want 2 — a record that exists but cannot be read is not 'nothing on record')"; }
grep -q "attempts.jsonl: cannot be read: Is a directory" "$TMP/err" \
    || { cat "$TMP/err" >&2; fail "phase 11h: the refusal does not name the record path and the errno"; }
if [ "$(id -u)" != 0 ]; then
    newdata
    plant_store 9 "8 in-progress 1700000000" "8 failed 1700000020"
    record "1700000000 $TASK attempt - - 0 /fx/disk/agent-config.dhall"
    record "1700000000 $TASK result - - 8 /fx/disk/agent-config.dhall"
    chmod 000 "$TMP/data/attempts.jsonl"
    out=$(run "$BIN" --store "$STORE"); rc=$?
    chmod 644 "$TMP/data/attempts.jsonl"
    [ "$rc" = 2 ] || fail "phase 11h: rc=$rc on an EACCES record (want 2)"
    grep -q "attempts.jsonl: cannot be opened: Permission denied" "$TMP/err" \
        || { cat "$TMP/err" >&2; fail "phase 11h: the EACCES record does not carry the errno"; }
fi
# 11i — the VERB surface: the bootlog's three read states are DISTINCT words
# there too (the journal's discipline).  FAILS if an unreadable or absent
# bootlog prints a COUNT ("boots 0" is a measurement never made), or if the
# states collapse into each other.
rm -rf "$VV/fx/disk/store/.bootlog"
mkdir "$VV/fx/disk/store/.bootlog" || fail "phase 11i: cannot plant the verb-side directory"
TXT=$(outverb "$VS" "$VV")
printf '%s\n' "$TXT" | grep -q "^exit=0$" \
    || { printf '%s\n' "$TXT" >&2; fail "phase 11i: an unreadable bootlog made the verb fail (CURRENT is readable; the bootlog is reported, not fatal)"; }
printf '%s\n' "$TXT" | grep -q "^bootlog UNREADABLE: .*\.bootlog: cannot be read: Is a directory$" \
    || { printf '%s\n' "$TXT" >&2; fail "phase 11i: the verb does not report the unreadable bootlog naming the path and errno"; }
printf '%s\n' "$TXT" | grep -q "^last UNKNOWN (the bootlog is UNREADABLE)" \
    || { printf '%s\n' "$TXT" >&2; fail "phase 11i: 'last' claims a verdict off a bootlog that could not be read"; }
printf '%s\n' "$TXT" | grep -qE "^boots " \
    && { printf '%s\n' "$TXT" >&2; fail "phase 11i: the verb printed a BOOTS COUNT for a bootlog it could not read"; }
rm -rf "$VV/fx/disk/store/.bootlog"
TXT=$(outverb "$VS" "$VV")
printf '%s\n' "$TXT" | grep -q "^bootlog absent (no .bootlog on this store" \
    || { printf '%s\n' "$TXT" >&2; fail "phase 11i: an absent bootlog is not its own state on the verb"; }
printf '%s\n' "$TXT" | grep -q "UNKNOWN, not zero" \
    || { printf '%s\n' "$TXT" >&2; fail "phase 11i: absence is not worded as unknown-vs-zero (the journal's own distinction)"; }
printf '%s\n' "$TXT" | grep -qE "^boots " \
    && { printf '%s\n' "$TXT" >&2; fail "phase 11i: an ABSENT bootlog printed a count"; }
{ printf '8 in-progress 1700000000\n8 failed 1700000020\n'; printf '%s' "9 in-prog"; } > "$VV/fx/disk/store/.bootlog"
TXT=$(outverb "$VS" "$VV")
printf '%s\n' "$TXT" | grep -q "^boots 2$" \
    || { printf '%s\n' "$TXT" >&2; fail "phase 11i: the torn line changed the count (want exactly the 2 complete lines)"; }
printf '%s\n' "$TXT" | grep -q "^bootlog_torn 1 line(s) skipped .*boots is a FLOOR" \
    || { printf '%s\n' "$TXT" >&2; fail "phase 11i: the torn tail is not reported as a floor"; }
printf '%s\n' "$TXT" | grep -q "^last 8 failed$" \
    || { printf '%s\n' "$TXT" >&2; fail "phase 11i: the last verdict was displaced by the torn tail"; }
note "verb side: UNREADABLE names path+errno / absent is unknown-not-zero / torn is a floor — and no count without a read"
# 11j — ASYMMETRY against the PINNED pre-fix tree (a FIXED revision, not a
# moving ref): $PIN_UNREADABLE is the last commit before the fix; its
# fx_outcome_verdict collapses the directory to RUN.  cmp proves the pin is
# not the working tree (the arm compares two different codes, never itself).
PIN_UNREADABLE="7afa0c2"
UNREAD_PIN=""
git -C "$ROOT" cat-file -e "$PIN_UNREADABLE^{commit}" 2>/dev/null \
    || UNREAD_PIN="revision $PIN_UNREADABLE unavailable (shallow clone or rewritten history)"
mkdir -p "$TMP/unreadpin/llm2" || fail "phase 11j: cannot create the pinned source dir"
if [ -z "$UNREAD_PIN" ]; then
    git -C "$ROOT" show "$PIN_UNREADABLE:src/llm2/outcome.c" > "$TMP/unreadpin/llm2/outcome.c" 2>/dev/null \
        || UNREAD_PIN="cannot extract src/llm2/outcome.c at $PIN_UNREADABLE"
    git -C "$ROOT" show "$PIN_UNREADABLE:src/llm2/outcome.h" > "$TMP/unreadpin/llm2/outcome.h" 2>/dev/null \
        || UNREAD_PIN="cannot extract src/llm2/outcome.h at $PIN_UNREADABLE"
    [ -z "$UNREAD_PIN" ] && cmp -s "$TMP/unreadpin/llm2/outcome.c" "$ROOT/src/llm2/outcome.c" \
        && UNREAD_PIN="the pinned $PIN_UNREADABLE outcome.c is IDENTICAL to the working tree — the arm would compare the code to itself"
fi
if [ -n "$UNREAD_PIN" ]; then
    echo "SKIP outcome: phase 11j (pre-fix asymmetry): $UNREAD_PIN"
else
    cat > "$TMP/unreadprobe.c" <<'CEOF'
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include "llm2/outcome.h"
int main(int argc, char **argv) {
    if (argc < 4) return 2;
    FxOutcome o;
    char rep[FX_OUTCOME_MSG_CAP];
    char err[512] = {0};
    FxVerdict v = fx_outcome_verdict(argv[1], argv[2], argv[3], NULL,
                                     &o, rep, sizeof rep, err, sizeof err);
    printf("verdict=%d err=[%s]\n", (int)v, err);
    return 0;
}
CEOF
    cc -std=c11 -O2 -Wall -Wextra -I"$TMP/unreadpin" \
       -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE \
       -o "$TMP/unreadprobe-pin" "$TMP/unreadprobe.c" "$TMP/unreadpin/llm2/outcome.c" \
       || fail "phase 11j: cannot build the probe against the pinned $PIN_UNREADABLE outcome.c"
    cc -std=c11 -O2 -Wall -Wextra -I"$ROOT/src" -I"$ROOT/src/llm2" \
       -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE \
       -o "$TMP/unreadprobe-fix" "$TMP/unreadprobe.c" "$ROOT/src/llm2/outcome.c" \
       || fail "phase 11j: cannot build the probe against this tree"
    newdata
    mkdir -p "$TMP/unreadstore/.db/snapshots"
    printf '8\n' > "$TMP/unreadstore/.db/snapshots/CURRENT"
    mkdir "$TMP/unreadstore/.bootlog" || fail "phase 11j: cannot plant the probe-side directory"
    record "1700000000 $TASK attempt - - 0 /fx/disk/agent-config.dhall"
    record "1700000000 $TASK result - - 8 /fx/disk/agent-config.dhall"
    PINV=$("$TMP/unreadprobe-pin" "$TMP/data" "$TASK" "$TMP/unreadstore") \
        || fail "phase 11j: the pinned probe failed"
    case "$PINV" in verdict=0\ err=[]) ;;
        *) fail "phase 11j: the pinned $PIN_UNREADABLE tree does not collapse the directory to a silent RUN ('$PINV') — the before-direction is not the measured defect";; esac
    FIXV=$("$TMP/unreadprobe-fix" "$TMP/data" "$TASK" "$TMP/unreadstore") \
        || fail "phase 11j: the fixed probe failed"
    case "$FIXV" in verdict=5\ err=\[*bootlog*) ;;
        *) fail "phase 11j: this tree does not refuse naming the bootlog ('$FIXV')";; esac
    note "ASYMMETRY PROVEN: identical store with a DIRECTORY at .bootlog — the pinned $PIN_UNREADABLE tree returns RUN (silent); this tree returns FX_VERDICT_ERROR naming the path"
fi

echo "PASS outcome: nothing-on-record RUNS and records the attempt; a run the TURN LIMIT"
echo "              stopped records NO done (and a run that FINISHED does); an activation that"
echo "              TOOK is not re-run, and a completion the record does not hold is never"
echo "              claimed; a FAILED one is reported and NOT repeated (exit 0, no dispatch,"
echo "              record untouched) with its way out NAMED — and with the RECOVERY JOURNAL"
echo "              read beside the bootlog: counted, absent-worded-as-unknown (never zero),"
echo "              floor on a torn tail, same-genhash recurrence bounded by the journal's"
echo "              own honesty limit, on the report AND the verb, and the pinned pre-read"
echo "              server prints none of it; an unreadable journal is its OWN state on both"
echo "              surfaces — never absent, never zero; a bootlog that EXISTS but cannot"
echo "              be read never collapses to \"no verdict line\" (FX_VERDICT_ERROR"
echo "              naming the path at every silence-deciding row, the done-in-force cell"
echo "              exempt), an absent one stays SILENCE, a torn tail NAMING mine refuses"
echo "              the re-run, a directory at attempts.jsonl is never \"no record\", and"
echo "              the pinned pre-fix tree still RUNs the very cell this tree refuses;"
echo "              a truncated report SAYS SO, and the"
echo "              cap it is derived against is measured at the field caps; a torn last line"
echo "              cannot decide a"
echo "              verdict; an unaccounted activation is settled by a completing run and is"
echo "              escapable with --reconsider; a drifted task identity is said OUT LOUD; a"
echo "              newline in the config cannot forge a record line; a --resume does not"
echo "              re-record its seed; the worst-case record round-trips; the store is never"
echo "              guessed (loud exit 2); and the pre-fix artifact re-runs the very task this"
echo "              one refuses."
exit 0
