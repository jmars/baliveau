#!/usr/bin/env bash
# tests/test_resume.sh — THE RESUME ORACLE.
#
# FAILS on the pristine tree and PASSES once RESUME is wired: phase 1 asserts a
# durable transcript exists after a mid-run death (pristine: ckpt_save runs only
# after the loop returns, so the file does not exist at all); phase 2 asserts a
# resumed run is SEEDED FROM that transcript rather than from -p.
#
# Determinism: no network, no sleeps.  The only ordering that matters —
# flush-then-kill — is structural: the loop notifies the transcript callback
# BEFORE it dispatches the tool (agent_loop.c:776 vs :783), so the killer tool
# cannot run until the assistant message is durable.
#
# Env knobs: KEEP_TMP=1 keeps the mktemp dir (for evidence);
# FX_FIXTURE_DIR overrides the recorded SSE fixtures' location.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN="$ROOT/build/fx-agent"
FIX="${FX_FIXTURE_DIR:-$ROOT/tests/fixtures}"
KILLER="$ROOT/tests/fixtures/kill_parent.sh"
SENTINEL=resume-probe-alpha

fail() { echo "FAIL $*" >&2; exit 1; }

[ -x "$BIN" ] || fail "phase 0: $BIN missing — run make first"
[ -f "$FIX/responses_tool.sse" ] || fail "phase 0: fixture $FIX/responses_tool.sse missing"
[ -f "$FIX/responses_simple.sse" ] || fail "phase 0: fixture $FIX/responses_simple.sse missing"
[ -x "$KILLER" ] || fail "phase 0: $KILLER is not executable"

TMP=$(mktemp -d)
cleanup() { [ "${KEEP_TMP:-0}" = 1 ] || rm -rf "$TMP"; }
trap cleanup EXIT
echo "== tmp: $TMP"

mkdir -p "$TMP/cfg"
# `args = [] : List Text` — the annotation is MANDATORY (dhall-c cannot infer an
# unannotated empty list; the whole config fail-opens to empty without it).
cat > "$TMP/cfg/config.dhall" <<DHALL
{ agents =
  [ { name = "fx"
    , agent_type = "agent"
    , mcp_servers =
      [ { command = "$KILLER", args = [] : List Text } ]
    }
  ]
}
DHALL

cp "$FIX/responses_tool.sse"   "$TMP/dev1.sse"
cp "$FIX/responses_simple.sse" "$TMP/dev2.sse"

# run <chardev> [extra argv...] — the offline chardev arm.  The harness APPENDS
# each request frame past the canned SSE bytes, so the chardev file itself is
# evidence of what the request carried.
run() {
  local dev="$1"; shift
  FX_CHARDEV="$dev" FX_AGENT_CONFIG_DIR="$TMP/cfg" \
  FX_AGENT_DATA="$TMP/data" HOME="$TMP" \
    "$BIN" -p "$SENTINEL" --agent fx --max-turns 3 --output text "$@"
}

echo "== phase 0: run 1 dies mid-dispatch (the killer tool SIGKILLs the harness)"
run "$TMP/dev1.sse" > "$TMP/run1.out" 2> "$TMP/run1.err"
rc1=$?
echo "   run 1 rc=$rc1 (SIGKILL => 137 on linux)"
[ "$rc1" -ge 128 ] || fail "phase 0: run 1 should die by signal (rc>=128), got rc=$rc1 (stderr: $(cat "$TMP/run1.err"))"

echo "== phase 1: the transcript is durable even though the run never returned"
msgs=$(ls -1 "$TMP"/data/sessions/*/messages.jsonl 2>/dev/null | head -1)
[ -n "$msgs" ] || fail "phase 1: no durable transcript after mid-run death (nothing under $TMP/data/sessions)"
lines=$(wc -l < "$msgs")
[ "$lines" -ge 2 ] || fail "phase 1: expected >=2 messages on disk, got $lines ($msgs)"
head -1 "$msgs" | grep -q "$SENTINEL" \
  || fail "phase 1: line 1 is not the seed prompt: $(head -1 "$msgs")"
grep -q get_weather "$msgs" \
  || fail "phase 1: the pre-death assistant tool_call is not on disk"
echo "   OK $msgs holds $lines lines; line 1 is the seed; get_weather is durable"

sid=$(ls -1 "$TMP/data/sessions" | grep -v '^\.' | head -1)
[ -n "$sid" ] || fail "phase 1: no session id under $TMP/data/sessions"
echo "   sid=$sid"

echo "== phase 2: --resume $sid seeds the loop from the pre-death transcript"
before=$(wc -c < "$TMP/dev2.sse")
run "$TMP/dev2.sse" --resume "$sid" > "$TMP/run2.out" 2> "$TMP/run2.err"
rc2=$?
[ "$rc2" -eq 0 ] || { sed -n '1,5p' "$TMP/run2.err" >&2; fail "phase 2: resume run rc=$rc2 (want 0)"; }
[ -s "$TMP/run2.out" ] || fail "phase 2: resume run printed nothing on stdout"
echo "   run 2 rc=0, stdout: $(cat "$TMP/run2.out")"

lines2=$(wc -l < "$msgs")
[ "$lines2" -ge 4 ] \
  || fail "phase 2: expected >=4 messages after the resume, got $lines2 ($msgs)"
nseed=$(grep -c "\"role\":\"user\",\"content\":\"$SENTINEL\"" "$msgs")
[ "$nseed" -eq 1 ] \
  || fail "phase 2: the seed line appears $nseed times (want exactly 1) — the on-disk skip count is wrong (double-append)"
grep -q get_weather "$msgs" \
  || fail "phase 2: get_weather absent from the resumed session — the transcript was not seeded"
grep -q 'rebooted before the tool returned' "$msgs" \
  || fail "phase 2: no synthetic tool result for the dangling pre-death tool call"
after=$(wc -c < "$TMP/dev2.sse")
[ "$after" -gt "$before" ] \
  || fail "phase 2: no request frame was appended to the chardev ($before -> $after bytes)"
grep -q get_weather "$TMP/dev2.sse" \
  || fail "phase 2: get_weather absent from run 2's request frame — run 2 did NOT seed from the transcript"
grep -q "$SENTINEL" "$TMP/dev2.sse" \
  || fail "phase 2: sentinel absent from run 2's request frame"
echo "   OK $msgs holds $lines2 lines; exactly 1 seed line; dev2 request frame ($before -> $after B) carries the pre-death transcript"

# ── phase 3: the double-append tripwire, MEASURED where it is observable ────
# A wrong skip count re-appends the loaded (pre-death) messages to disk.  In a
# run that COMPLETES that is invisible: the end-of-run ckpt_save rewrites the
# file from the in-memory list, so phase 2's "exactly 1 seed line" passes even
# with cb.skip forced to 0 (MEASURED: that mutant passes phase 2).  The
# duplicate is only observable while it is UNHEALED — i.e. when the resumed run
# also dies before ckpt_save.  That is phase 3, and it is the shape that
# actually matters: a resume that dies leaves a transcript whose NEXT resume
# must still be well-formed (a duplicated assistant tool_call with the same
# call id is malformed for the provider).
echo "== phase 3: a resumed run that dies mid-dispatch leaves NO re-appended seed"
cp "$FIX/responses_tool.sse" "$TMP/dev3.sse"   # fresh copy: the killer tool dies again
run "$TMP/dev3.sse" --resume "$sid" > "$TMP/run3.out" 2> "$TMP/run3.err"
rc3=$?
echo "   run 3 rc=$rc3"
[ "$rc3" -ge 128 ] || fail "phase 3: run 3 should die by signal (rc>=128), got rc=$rc3 (stderr: $(cat "$TMP/run3.err"))"
lines3=$(wc -l < "$msgs")
[ "$lines3" -gt "$lines2" ] \
  || fail "phase 3: the resumed run's own messages were not flushed before it died ($lines2 -> $lines3 lines)"
nseed3=$(grep -c "\"role\":\"user\",\"content\":\"$SENTINEL\"" "$msgs")
[ "$nseed3" -eq 1 ] \
  || fail "phase 3: the UNHEALED transcript holds the seed line $nseed3 times (want exactly 1) — the on-disk skip count is wrong (double-append)"
ngw=$(grep -c get_weather "$msgs")
[ "$ngw" -eq 2 ] \
  || fail "phase 3: expected exactly 2 get_weather messages (the seeded pre-death one + this run's fresh flush), got $ngw"
echo "   OK unhealed transcript: $lines3 lines ($lines2 -> $lines3), 1 seed line, 2 get_weather lines, no re-appended seed"

# ── phase 4: a TORN TAIL line (the crash-mid-flush shape) is skipped, healed ─
# The per-message flush is one write(2) per line, so a crash mid-flush can only
# leave a PREFIX of a line.  ckpt_load must skip it (FAIL-OPEN, never a hard
# error) and the end-of-run ckpt_save must drop it, or a session that dies
# during a flush would be permanently unresumable.
echo "== phase 4: a torn tail line does not block the resume"
cp "$FIX/responses_simple.sse" "$TMP/dev4.sse"
printf '{"role":"assistant","content":"torn-mid-flus' >> "$msgs"   # no newline: an incomplete line
before4=$(wc -l < "$msgs")
run "$TMP/dev4.sse" --resume "$sid" > "$TMP/run4.out" 2> "$TMP/run4.err"
rc4=$?
[ "$rc4" -eq 0 ] || { sed -n '1,5p' "$TMP/run4.err" >&2; fail "phase 4: resume past a torn tail rc=$rc4 (want 0)"; }
grep -q torn-mid-flus "$msgs" \
  && fail "phase 4: the torn line survived the end-of-run rewrite (self-heal did not run)"
nseed4=$(grep -c "\"role\":\"user\",\"content\":\"$SENTINEL\"" "$msgs")
[ "$nseed4" -eq 1 ] \
  || fail "phase 4: the seed line appears $nseed4 times after the torn-tail resume (want exactly 1)"
lines4=$(wc -l < "$msgs")
[ "$lines4" -gt "$before4" ] \
  || fail "phase 4: expected the healed transcript to grow past $before4 lines, got $lines4"
echo "   OK torn tail skipped fail-open; transcript healed to $lines4 lines, 1 seed line"

echo "PASS resume: mid-run death -> durable transcript -> resumed run seeded from it -> resume-of-a-resume stays well-formed -> torn tail healed"
