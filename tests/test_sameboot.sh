#!/bin/sh
# tests/test_sameboot.sh — THE SAME-BOOT GUARD (the control-channel
# activation's self-interaction), host-side, no network, no sleeps.
#
# WHAT THIS GATES.  fx_activate routes through PID1's control channel, whose
# handler COMMITS the generation live: it rebuilds the service table and the
# supervisor's next pass starts every service fresh — including, for a config
# that REDECLARES the agent service, a SECOND instance of the agent while the
# first is still mid-turn.  That successor reads the durable record before
# the first instance exits (no `done`) and before the re-armed boot window has
# judged the new generation (the re-arm writes NO .bootlog line), so the
# ordinary verdict would be RUN and the successor would RE-ISSUE the
# activation — an unbounded in-boot oscillator.  The guard in
# src/llm2/agent_main.c stops a run whose own recorded activation IS the
# store's CURRENT while the bootlog says this boot STARTED on an older
# generation (the store moved mid-boot — only PID1's activate/rollback
# handlers do that).
#
# THE FOUR CASES (each can fail):
#   A  mid-boot shape: boot entry v5 < CURRENT v7, record result v7
#      -> the guard FIRES: the SAME-BOOT report on stdout, exit 0, before any
#      loop/config work.  A guardless binary sails past this point and dies
#      in config_load with a NONZERO exit — so this case cannot pass inert.
#   B  fresh-boot shape: boot entry v7 == CURRENT v7, record result v7, no
#      verdict for v7 yet -> the guard is SILENT (equality, not a move): the
#      run PROCEEDS past the guard and fails later, loudly, in config_load —
#      proving the guard did not swallow the ordinary RUN row.
#   C  the DUPLICATE's EARLIER failure point: same fresh-boot record, a REAL
#      fcntl-held single-writer LOCK on <data>/LOCK (dl_open2's own
#      mechanism) -> the successor REPORTS (RUNSTORE HELD BY ANOTHER WRITER,
#      DUPLICATE AGENT INSTANCE) and exits 0.  A binary without the arm dies
#      nonzero on runstore_open — the exit that puts ST_FAILED on the agent
#      row and fails the activated generation's boot verdict (measured on
#      qemu-agent-b2's A1 console), so this case cannot pass inert either.
#   D  the control: the SAME invocation on a FREE store sails PAST
#      ckpt_runstore open (LOCK created, no successor report) and fails
#      later for its own reasons — the successor arm cannot swallow an
#      ordinary run.
#   The version needle: PID1's channel reply ("activated version N") must
#      yield the generation to the record — via the fx-agent binary's own
#      surface this is proven end-to-end by the qemu gates; here the unit is
#      pinned by feeding BOTH reply shapes through a tiny C harness that
#      links activation_version_of's translation unit?  NO — the function is
#      static.  Instead: the channel shape is asserted WHERE IT IS PRODUCED
#      (tests/verbs-smoke.sh's channel arm asserts the reply line verbatim),
#      and the record's version parsing of that shape is asserted by the
#      in-guest gates (the transcript's result line names the generation).
#      This file deliberately asserts only what runs on the host.
#
# Env: none.  Exit 0 pass, 1 fail.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN="$ROOT/build/fx-agent"
fail() { echo "test_sameboot: FAIL: $*" >&2; exit 1; }
[ -x "$BIN" ] || fail "build/fx-agent missing — run make"

WORK=$(mktemp -d /tmp/fx-sameboot.XXXXXX) || fail mktemp
trap 'rm -rf "$WORK"' EXIT

PROMPT="apply the config change to this machine"
AGENT=fx

# the task id the binary will compute: FNV-1a-64(agent ++ "\x1f" ++ prompt),
# %016llx — outcome.c fx_outcome_task_id, reimplemented here bit-for-bit.
TASK=$(python3 - "$AGENT" "$PROMPT" <<'PYEOF'
import sys
agent, prompt = sys.argv[1], sys.argv[2]
h = 1469598103934665603
for part in (agent, "\x1f", prompt):
    for b in part.encode():
        h ^= b
        h = (h * 1099511628211) & 0xFFFFFFFFFFFFFFFF
print("%016x" % h)
PYEOF
) || fail "cannot compute the task id"
echo "$TASK" | grep -Eq '^[0-9a-f]{16}$' || fail "task id malformed: $TASK"

mkstore() { # mkstore DIR CURRENT BOOTLOG_LINES...
    _d=$1 _cur=$2; shift 2
    mkdir -p "$_d/.db/snapshots" || fail mkstore
    printf '%s\n' "$_cur" > "$_d/.db/snapshots/CURRENT" || fail mkstore-current
    : > "$_d/.bootlog"
    for _l in "$@"; do printf '%s\n' "$_l" >> "$_d/.bootlog"; done
}
mkrecord() { # mkrecord DATA TASK VERSION CONFIG
    mkdir -p "$1" || fail mkrecord
    {
        echo "1790000001 $2 agent  sess01 run01 0 $AGENT"
        echo "1790000002 $2 attempt sess01 run01 0 $4"
        echo "1790000003 $2 result  sess01 run01 $3 $4"
    } > "$1/attempts.jsonl"
}

CFG=/fx/disk/agent-config.dhall

# ── case A: the mid-boot shape — the guard must FIRE ─────────────────────
SA="$WORK/store-a"; DA="$WORK/data-a"
mkstore "$SA" 7 "5 in-progress 1790000001 4e0001" "5 ok 1790000010 4e0001"
mkrecord "$DA" "$TASK" 7 "$CFG"
OUT_A=$(VIBE_RUNTIME_DIR="$DA" "$BIN" --agent "$AGENT" -p "$PROMPT" \
             --store "$SA" --output text 2>"$DA/err"); RC_A=$?
echo "$OUT_A" | grep -q "SAME-BOOT ACTIVATION ON RECORD" \
    || { echo "--- case A stdout:"; echo "$OUT_A"; echo "--- case A stderr:";
         cat "$DA/err"; fail "case A: the guard did not REPORT (rc=$RC_A)"; }
echo "$OUT_A" | grep -q "NOT RE-RUNNING IT" \
    || fail "case A: the report does not say NOT RE-RUNNING"
echo "$OUT_A" | grep -q "started at v5" \
    || fail "case A: the report does not name the boot-entry generation v5"
[ "$RC_A" = 0 ] || fail "case A: exit $RC_A (the guard must stop cleanly, exit 0)"
grep -q "config_load\|not found in runtime config" "$DA/err" \
    && fail "case A: the run went PAST the guard into config loading"

# ── case B: the fresh-boot shape — the guard must be SILENT ──────────────
SB="$WORK/store-b"; DB="$WORK/data-b"
mkstore "$SB" 7 "7 in-progress 1790000001 4e0002"
mkrecord "$DB" "$TASK" 7 "$CFG"
OUT_B=$(VIBE_RUNTIME_DIR="$DB" "$BIN" --agent "$AGENT" -p "$PROMPT" \
             --store "$SB" --output text 2>"$DB/err"); RC_B=$?
echo "$OUT_B" | grep -q "SAME-BOOT ACTIVATION ON RECORD" \
    && fail "case B: the guard FIRED on a fresh boot (boot entry == CURRENT — no mid-boot move)"
[ "$RC_B" = 0 ] \
    && { echo "--- case B stdout:"; echo "$OUT_B"; fail "case B: rc 0 — the run neither proceeded nor failed honestly"; }
grep -q "config" "$DB/err" \
    || { echo "--- case B stderr:"; cat "$DB/err"; \
         fail "case B: the run did not PROCEED past the guard (no config_load failure — the guard swallowed the ordinary RUN row)"; }

# ── case C: the DUPLICATE's earlier failure point — a HELD runstore ──────
# The guard above fires only on POSITIVE record evidence (a result row for
# THIS task); the second instance a restart sweep starts when the activated
# config REDECLARES the agent has a DIFFERENT task id (a different argv
# prompt), so its record read is silence, the guard cannot fire, and the run
# proceeds — config_load, the task/agent binding — until ckpt_run_open hits
# dl_open2's single-writer fcntl LOCK on <data>/LOCK held by the live first
# instance.  MEASURED (qemu-agent-b2's A1 console): that duplicate died
# NONZERO there, landed in ST_FAILED, and the any_failed arm failed the NEW
# generation's boot verdict — an agent marking its own successful activation
# FAILED.  The correct successor behaviour is the guard's, applied at this
# EARLIER point: stop, report, exit 0.  The lock is held here by a REAL
# fcntl WRLCK from a helper process — the same mechanism dl_open2 honours,
# not a string fixture.
SC="$WORK/store-c"; DC="$WORK/data-c"
mkstore "$SC" 7 "7 in-progress 1790000001 4e0003"   # fresh-boot shape: no guard
mkrecord "$DC" "$TASK" 7 "$CFG"
CFGDIR_C="$WORK/cfg-c"; mkdir -p "$CFGDIR_C" || fail "cannot mkdir $CFGDIR_C"
cat > "$CFGDIR_C/config.dhall" <<'DHALL'
{ agents =
  [ { name = "fx"
    , agent_type = "agent"
    , mcp_servers =
      [ { command = "/bin/true"
        , args = [] : List Text
        }
      ] : List { command : Text, args : List Text }
    }
  ]
}
DHALL
mkdir -p "$DC" || fail "cannot mkdir $DC"
: > "$DC/LOCK" || fail "cannot create the LOCK file"
python3 - "$DC/LOCK" <<'PYEOF' &
import fcntl, sys, time
f = open(sys.argv[1], "r+")
fcntl.lockf(f, fcntl.LOCK_EX | fcntl.LOCK_NB)  # the WRLCK dl_open2 takes
time.sleep(120)
PYEOF
LOCKPID=$!
sleep 0.3  # the helper must hold the lock BEFORE the binary runs
OUT_C=$(VIBE_RUNTIME_CONFIG_DIR="$CFGDIR_C" VIBE_RUNTIME_DIR="$DC" "$BIN" \
             --agent "$AGENT" -p "$PROMPT" --store "$SC" --output text \
             2>"$DC/err"); RC_C=$?
kill "$LOCKPID" 2>/dev/null; wait "$LOCKPID" 2>/dev/null
echo "$OUT_C" | grep -q "RUNSTORE HELD BY ANOTHER WRITER" \
    || { echo "--- case C stdout:"; echo "$OUT_C"; echo "--- case C stderr:"; cat "$DC/err"; \
         fail "case C: the held-lock successor did not REPORT (rc=$RC_C)"; }
echo "$OUT_C" | grep -q "DUPLICATE AGENT INSTANCE" \
    || fail "case C: the report does not say what the run IS (a duplicate instance)"
[ "$RC_C" = 0 ] \
    || fail "case C: exit $RC_C — a successor dying nonzero on a held lock fails its generation's boot verdict"
grep -q "runstore_open" "$DC/err" \
    && fail "case C: the held lock was reported as an ordinary runstore_open FAULT (the successor case must not be an error)"

# ── case D: an UNHELD store must NOT trip the successor arm ──────────────
# The exemption must not swallow ordinary runs: with the lock free the same
# invocation sails PAST ckpt_run_open (it creates the store and proceeds
# toward the loop, failing later for its own reasons — here the /bin/true
# MCP handshake).  No successor report, no exit-0-at-the-lock.
SD="$WORK/store-d"; DD="$WORK/data-d"
mkstore "$SD" 7 "7 in-progress 1790000001 4e0004"
mkrecord "$DD" "$TASK" 7 "$CFG"
CFGDIR_D="$WORK/cfg-d"; mkdir -p "$CFGDIR_D" || fail "cannot mkdir $CFGDIR_D"
cp "$CFGDIR_C/config.dhall" "$CFGDIR_D/config.dhall" || fail "cannot copy the case-D config"
OUT_D=$(VIBE_RUNTIME_CONFIG_DIR="$CFGDIR_D" VIBE_RUNTIME_DIR="$DD" "$BIN" \
             --agent "$AGENT" -p "$PROMPT" --store "$SD" --output text \
             2>"$DD/err"); RC_D=$?
echo "$OUT_D" | grep -q "RUNSTORE HELD BY ANOTHER WRITER" \
    && fail "case D: the successor arm FIRED on an unheld store"
grep -q "runstore_open" "$DD/err" \
    && fail "case D: runstore_open failed on a FREE store — the arm's premise is wrong"
[ -e "$DD/LOCK" ] || fail "case D: the run never opened the runstore (no LOCK created — it did not get past ckpt_run_open)"
[ "$RC_D" = 0 ] \
    && { echo "--- case D stdout:"; echo "$OUT_D"; echo "--- case D stderr:"; cat "$DD/err"; \
         fail "case D: rc 0 — the run should have proceeded into the loop and failed there for its own (/bin/true MCP) reasons"; }

echo "test_sameboot: PASS — mid-boot successor stops (boot entry v5 < CURRENT v7, reported, exit 0); fresh boot proceeds (entry == CURRENT); a DUPLICATE on a held runstore reports and exits 0; an unheld store does not trip the arm"
