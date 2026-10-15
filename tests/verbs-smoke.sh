#!/bin/sh
# tests/verbs-smoke.sh — host smoke test for the fx-verbs MCP stdio tool server
# (tools/fx-verbs-server.c, native build).
#
# Builds a stub root ($ROOT) laid out like the guest:
#   $ROOT/bin/{fx-activate}                  the RUNNING root's own binaries
#                                            (fx-init's activation symlinks these
#                                            into the store dir its install fact
#                                            names) — they MUST win
#   $ROOT/usr/fx-core/bin/{fxctl,fxstore,    host shell-script stubs (fixtures
#     fx-activate}                            only — the server itself never
#                                            uses a shell); fx-activate here is
#                                            the mkinitramfs-staged COPY, which
#                                            must NOT shadow $ROOT/bin
#   $ROOT/fx/store/bin/fxctl (decoy)
#   $ROOT/fx/disk/store/                     the store-scoped verbs' store
#   $ROOT/run/fx/control.{in,out}            a fake PID1 speaking the REAL fifo
#                                            line protocol (created mid-run for
#                                            the fx_activate channel arm, then
#                                            removed for the fallback arm)
# and drives the server over stdin/stdout with newline-delimited JSON-RPC 2.0
# frames, asserting:
#   the MCP handshake and framing (initialize / notifications/initialized
#   silence / tools/list / tools/call / ping / id echo incl. string ids),
#   every verb row of the table (exec verbs via the stubs, fx_read/fx_write/
#   fx_ls natively under $ROOT), the fx_store_verify EXIT-1-on-drift gate
#   surfacing as "exit=1" in the reply text, fx_activate's CONTROL-CHANNEL
#   route (the request line `activate <config>' on control.in; PID1's
#   "activated version N"+OK reply surfacing exit=0; PID1's ERR refusal —
#   the service-table overflow shape — surfacing verbatim with exit=1; a
#   whitespace config path refused BEFORE the channel; and the channel-less
#   fallback exec'ing the pinned fx-activate argv behind a LOUD
#   reduced-semantics banner), root-based command resolution
#   (the running root's bin wins; usr/fx-core/bin then beats the store decoy),
#   the STORE-SCOPED refusal (a row carrying /fx/disk/store will not run when
#   that store is absent — it names the path instead of exec'ing a stub that
#   would have failed downstream), the WRITABLE SET (fx_write refuses every
#   path outside the host-declared FX_AGENT_WRITABLE set — including the
#   harness's own record attempts.jsonl, a '..' spelling of it, and a symlink
#   at the final path — while the set's own paths still write; and with the
#   variable UNSET the default set is exactly /fx/disk/agent-config.dhall),
#   THE READ/LIST ROOT BOUND (fx_read/fx_ls take the SAME canon_root_rel gate as
#   fx_write: a '..' that climbs ABOVE the stub root is REFUSED, naming the path
#   and the root, and a host file planted just outside the root does NOT come
#   back — while a '..' that stays INSIDE the root still reads and lists; the
#   escape is shown by ASYMMETRY against the pinned pre-fix server, which
#   returns the host bytes),
#   the scrubbed child env (RATTAN_*/LD_* absent from the verb's environment),
#   and the failure paths (unknown tool -> JSON-RPC error, not a crash;
#   oversize line -> error and the server survives; verb binary missing ->
#   exit=127).
#
# The guest (musl) build is verified by tools/build.sh; this test runs the
# native build against the stub root.

set -e
cd "$(dirname "$0")/.."

# FX_VERBS_SERVER selects the binary under test — the NATIVE build by default.
# It exists so an assertion in here can be PROVEN fireable: build a
# deliberately reverted/broken variant elsewhere (e.g. the pre-2026-10
# resolve_command order) and run THIS test against it, expecting the named
# checks to FAIL.
BIN=${FX_VERBS_SERVER:-build/fx-verbs-server}
if [ ! -x "$BIN" ]; then
    [ -n "${FX_VERBS_SERVER:-}" ] && { echo "FX_VERBS_SERVER=$BIN is not executable" >&2; exit 2; }
    tools/build.sh
fi

ROOT=$(mktemp -d /tmp/fxv-smoke.XXXXXX)
# A host directory just OUTSIDE the stub root, planted so the read/ls root
# bound's pre-fix escape is VISIBLE (pre-fix returns these bytes) — the same
# discipline as the write-side '..' arms.
OUTSIDE="$ROOT-escape"
PRE_DIR=""
cleanup() {
    rm -rf "$ROOT"
    rm -rf "$OUTSIDE"
    if [ -n "$PRE_DIR" ]; then rm -rf "$PRE_DIR"; fi
    if [ -n "${PRE_OPS_DIR:-}" ]; then rm -rf "$PRE_OPS_DIR"; fi
}
trap cleanup EXIT
mkdir -p "$OUTSIDE/hostdir"
printf 'HOST-SECRET-OUTSIDE-ROOT\n' > "$OUTSIDE/secret.txt"
printf 'outside-dir-entry\n' > "$OUTSIDE/hostdir/marker.txt"

# ── THE PRE-FIX ARTIFACT of the read/ls root bound (the ASYMMETRY arm) ──────
# native_read / native_ls used to root_join the request WITHOUT canonicalizing
# it, so a '..' climbed above FX_VERB_ROOT.  This builds the PINNED pre-fix
# server from the same sources and the driver runs the SAME escaping requests
# against the SAME stub root through it: pre-fix they SUCCEED, post-fix they
# are REFUSED.  House discipline: a FIXED revision, a cat-file guard, and a
# cmp proof that the pinned source DIFFERS from the working tree (identical
# would compare the code to itself and prove nothing).  No git / no pin => the
# driver prints a LOUD skip instead of claiming an asymmetry it did not run.
PRE_VERBS_REV="217c7c7"   # fx-harness at the commit before the root-bound fix
PRE_BIN=""
if git cat-file -e "$PRE_VERBS_REV^{commit}" 2>/dev/null; then
    PRE_DIR=$(mktemp -d /tmp/fxv-prefix.XXXXXX)
    if git show "$PRE_VERBS_REV:tools/fx-verbs-server.c" > "$PRE_DIR/pre.c" 2>/dev/null; then
        if cmp -s "$PRE_DIR/pre.c" tools/fx-verbs-server.c; then
            echo "verbs-smoke: SKIP (root-bound asymmetry): $PRE_VERBS_REV's server source is IDENTICAL to the working tree — the arm would compare the code to itself" >&2
            rm -rf "$PRE_DIR"; PRE_DIR=""
        else
            if cc -std=c11 -O2 -g -Wall -Wextra -Isrc -Isrc/vendor/yyjson \
                  -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE \
                  -o "$PRE_DIR/pre-verbs-server" "$PRE_DIR/pre.c" \
                  src/agent/outcome.c src/vendor/yyjson/yyjson.c 2>"$PRE_DIR/cc.log"; then
                PRE_BIN="$PRE_DIR/pre-verbs-server"
            else
                echo "verbs-smoke: SKIP (root-bound asymmetry): cannot build the pinned $PRE_VERBS_REV server" >&2
                cat "$PRE_DIR/cc.log" >&2
                rm -rf "$PRE_DIR"; PRE_DIR=""
            fi
        fi
    else
        echo "verbs-smoke: SKIP (root-bound asymmetry): cannot extract $PRE_VERBS_REV:tools/fx-verbs-server.c" >&2
        rm -rf "$PRE_DIR"; PRE_DIR=""
    fi
else
    echo "verbs-smoke: SKIP (root-bound asymmetry): pre-fix revision $PRE_VERBS_REV unavailable (shallow clone?)" >&2
fi

# ── THE PRE-FIX ARTIFACT of the OPS-POLICY seat (the P0 ASYMMETRY arm) ───────
# The policy-deny case (a protected path + a boot-not-ok verdict, BOTH inside
# the writable set so the FLOOR passes) must SUCCEED on the pre-seat server
# and be REFUSED naming rule D2 on the current one — a policy layer proven
# only post-change is a layer on trust.  The pinned rev is the S1 commit
# (the ops artifacts + gate landed; the verbs server carries NO seat).  Same
# house discipline as the root-bound PRE above: a fixed rev, a cat-file
# guard, a cmp proof that the pinned source DIFFERS from the working tree,
# and a LOUD skip (never a claimed asymmetry that did not run).
PRE_OPS_REV="e2ebb39"   # ops-policy S1: artifacts + gate; the seat is S2
PRE_OPS_BIN=""
if git cat-file -e "$PRE_OPS_REV^{commit}" 2>/dev/null; then
    PRE_OPS_DIR=$(mktemp -d /tmp/fxv-ops-prefix.XXXXXX)
    if git show "$PRE_OPS_REV:tools/fx-verbs-server.c" > "$PRE_OPS_DIR/pre.c" 2>/dev/null; then
        if cmp -s "$PRE_OPS_DIR/pre.c" tools/fx-verbs-server.c; then
            echo "verbs-smoke: SKIP (ops-policy asymmetry): $PRE_OPS_REV's server source is IDENTICAL to the working tree — the arm would compare the code to itself" >&2
            rm -rf "$PRE_OPS_DIR"; PRE_OPS_DIR=""
        else
            if cc -std=c11 -O2 -g -Wall -Wextra -Isrc -Isrc/vendor/yyjson \
                  -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE \
                  -o "$PRE_OPS_DIR/pre-ops-server" "$PRE_OPS_DIR/pre.c" \
                  src/agent/outcome.c src/vendor/yyjson/yyjson.c 2>"$PRE_OPS_DIR/cc.log"; then
                PRE_OPS_BIN="$PRE_OPS_DIR/pre-ops-server"
            else
                echo "verbs-smoke: SKIP (ops-policy asymmetry): cannot build the pinned $PRE_OPS_REV server" >&2
                cat "$PRE_OPS_DIR/cc.log" >&2
                rm -rf "$PRE_OPS_DIR"; PRE_OPS_DIR=""
            fi
        fi
    else
        echo "verbs-smoke: SKIP (ops-policy asymmetry): cannot extract $PRE_OPS_REV:tools/fx-verbs-server.c" >&2
        rm -rf "$PRE_OPS_DIR"; PRE_OPS_DIR=""
    fi
else
    echo "verbs-smoke: SKIP (ops-policy asymmetry): pre-seat revision $PRE_OPS_REV unavailable (shallow clone?)" >&2
fi

# The FOLDING arm (P8) and the grammar-drift arm (P10) drive the S1 compiler
# tooling (policy/ops/eval_ops.py consumes `le` as a dependency) — the SAME
# three-step sibling resolution tests/test_ops_policy.sh uses, exported for
# the python driver.  A le-less host SKIPS those arms loudly below; it never
# claims a folding proof it did not run.
LE_ROOT="${LE_DIR:-}"
if [ -z "$LE_ROOT" ]; then
    REPO_ABS=$(cd "$(dirname "$0")/.." && pwd)
    SIBS="${FX_SIBLINGS:-$(cd "$REPO_ABS/.." && pwd)}"
    [ -d "$SIBS/fx-init" ] || [ -n "${FX_SIBLINGS:-}" ] || SIBS="$HOME/fixpoint-linux"
    for cand in "$SIBS/logical-english" "$REPO_ABS/../logical-english" "$HOME/logical-english"; do
        if [ -f "$cand/le/__init__.py" ]; then LE_ROOT="$cand"; break; fi
    done
fi
if [ -f "$LE_ROOT/le/__init__.py" ]; then
    export LE_DIR="$LE_ROOT"
else
    echo "verbs-smoke: SKIP (P8 folding / P10 grammar arms): no le checkout (set LE_DIR)" >&2
fi

# ── the stub root ────────────────────────────────────────────────────────────
mkdir -p "$ROOT/usr/fx-core/bin" "$ROOT/fx/store/bin" "$ROOT/bin" "$ROOT/fx/disk/store"

cat > "$ROOT/usr/fx-core/bin/fxctl" <<STUB
#!/bin/sh
# fxctl's fifo mode passes a bare --fifo FIRST (the in-guest transport flag,
# stripped before the request line is built) — the stub shifts it off the same
# way so the case arms below see the real subcommand.
case "\$1" in --fifo) shift ;; esac
cmd="\$1"; shift
case "\$cmd" in
  q)        echo "relation:\$1" ;;
  status)   echo "gen 42 current"; echo "svc consh ok" ;;
  activate) echo "activated:\$1" ;;
  rollback) echo "rolled:\$1" ;;
  *)        echo "fxctl-stub: unknown \$cmd" >&2; exit 2 ;;
esac
env | sort > "$ROOT/envdump"
exit 0
STUB

# fx-activate: the fx_activate VERB's target.  TWO copies, as on a real guest:
#   $ROOT/bin/fx-activate          the RUNNING generation's own binary (fx-init's
#                                 activation materializes it as a symlink into
#                                 the store dir its install fact names) — the
#                                 one PID1's activate handler execs, and the one
#                                 the lookup MUST pick
#   $ROOT/usr/fx-core/bin/fx-activate
#                                 the mkinitramfs -b STAGED copy — must NOT
#                                 shadow the above
# Both must see the guest's persistent store + the image's frozen package set
# as FIXED args, with the config path appended.
cat > "$ROOT/bin/fx-activate" <<STUB
#!/bin/sh
echo "RUNBIN fx-activate args: \$*"
env | sort > "$ROOT/envdump"
exit 0
STUB

cat > "$ROOT/usr/fx-core/bin/fx-activate" <<STUB
#!/bin/sh
echo "STAGED-COPY fx-activate args: \$*"
env | sort > "$ROOT/envdump"
exit 0
STUB

cat > "$ROOT/usr/fx-core/bin/fxstore" <<STUB
#!/bin/sh
cmd="\$1"; shift
case "\$cmd" in
  what)   echo "what:\$1:install" ;;
  why)    echo "why:\$1 closure=2 roots=consh" ;;
  verify)
    echo "fxstore args: \$*"
    if [ -f "$ROOT/drift-flag" ]; then
      echo "etc/motd: missing: last installed by gen 1"
      exit 1
    fi
    echo "verify OK"
    exit 0 ;;
  build)
    echo "build args: \$*"
    pwd > "$ROOT/builddump"
    env | sort > "$ROOT/envdump"
    exit 0 ;;
  *) echo "fxstore-stub: unknown \$cmd" >&2; exit 2 ;;
esac
STUB

# the fx_build row's PINNED working directory: fxstore loads package-set.dhall
# from its cwd, and the image's frozen set lives at /usr/fx.  A stub file (the
# chdir target; the stub never reads it) so the child's chdir succeeds.
mkdir -p "$ROOT/usr/fx"
printf '{ packages = [] : List { name : Text } }\n' > "$ROOT/usr/fx/package-set.dhall"

printf '#!/bin/sh\necho DECOY-must-not-run\n' > "$ROOT/fx/store/bin/fxctl"
chmod +x "$ROOT/usr/fx-core/bin/fxctl" "$ROOT/usr/fx-core/bin/fxstore" \
         "$ROOT/usr/fx-core/bin/fx-activate" "$ROOT/bin/fx-activate" \
         "$ROOT/fx/store/bin/fxctl"

# ── the store's OUTCOME files (fx_outcome / fx_generation read these) ───────
# The boot history is fx-init's own disk .bootlog VERBATIM (B2's arm-2 boot B2:
# the agent's crasher generation v7 booted and FAILED, so CURRENT is 7 and the
# last verdict in the bootlog is "7 failed" — the roll-forward state an agent
# must be able to SEE).  One "<version> <status> <epoch>" line per boot.
mkdir -p "$ROOT/fx/disk/store/.db/snapshots"
printf '7\n' > "$ROOT/fx/disk/store/.db/snapshots/CURRENT"
cat > "$ROOT/fx/disk/store/.bootlog" <<'BOOTLOG'
3 in-progress 1791556214
3 ok 1791556226
5 in-progress 1791556244
5 ok 1791556274
7 in-progress 1791556292
7 failed 1791556292
BOOTLOG
# The RECOVERY JOURNAL beside it (fx-init 4d6a8c2's format, from the writer):
# '#' header lines, then one "<epoch> <published> <from> <genhash>" data line
# per AUTOMATIC roll-forward.  This fixture is the OSCILLATOR the journal
# exists to make visible: the same content (deadbeef...) recovered to TWICE,
# plus a torn last line (a crash mid-append) — count 3, recurrence x2, floor.
# The torn line is written WITHOUT its newline, exactly as a torn append is.
cat > "$ROOT/fx/disk/store/.recovery" <<'RECOVERY'
# fx-init recovery journal. One DATA line per AUTOMATIC roll-forward:
# fx-init republished an older ok generation because the current
# version's last .bootlog verdict was failed/in-progress.
# line: <epoch-s> <published-version> <from-failed-version> <content-genhash|->
1791556230 4 3 deadbeef0123456789abcdefdeadbeef0123456789abcdef
1791556258 6 5 deadbeef0123456789abcdefdeadbeef0123456789abcdef
1791556288 8 7 cafef00d0123456789abcdef
RECOVERY
printf '%s' "1791556310 10 9 dead" >> "$ROOT/fx/disk/store/.recovery"

# ── the driver ───────────────────────────────────────────────────────────────
python3 - "$ROOT" "$BIN" "$PRE_BIN" "$OUTSIDE" "$PRE_OPS_BIN" <<'DRIVER'
import json, os, select, shutil, subprocess, sys, time

root = sys.argv[1]
bin = os.path.abspath(sys.argv[2])
pre_bin = sys.argv[3]
outside = sys.argv[4]
pre_ops_bin = sys.argv[5]

env = {
    "PATH": "/usr/bin:/bin",
    "FX_VERB_ROOT": root,
    # the host-declared writable set for THIS smoke run: /note.txt, plus
    # /note-link (a symlink fixture) so the O_NOFOLLOW check below reaches
    # open() instead of being refused by the set gate first, plus the
    # ROOT-RELATIVE entry fx/rel-note.txt (the spelling the docs document —
    # 13c proves it grants, and grants only, the one file it names)
    "FX_AGENT_WRITABLE": "/note.txt:/note-link:fx/rel-note.txt",
    # planted keys the verb child's scrubbed env must NOT contain:
    "RATTAN_ENABLE": "1",
    "LD_PRELOAD": "/tmp/evil.so",
    "HOME": "/home/nobody",
    # THE HANDLER'S MARKER, planted (12).  fx-init tells its OWN activate
    # child not to self-record by setting FX_OPERATOR_RECORDED in that
    # child's env; the fallback's child env is an explicit WHITELIST
    # (build_verb_envp), so the marker must NOT reach a direct exec even
    # when the server's own environment carries it — which is what makes
    # "a direct exec always self-records, a channel child never does" a
    # structural claim rather than a convention.
    "FX_OPERATOR_RECORDED": "1",
}
server = subprocess.Popen([bin], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, env=env)

# Raw-fd transport with OUR OWN line buffering (the mcp_client ReadBuf
# pattern).  server.stdout is a BufferedReader: readline() pulls whole chunks,
# so replies can sit in its userspace buffer where a raw select() never fires
# — mixing the two silently swallows replies.
checks = {"n": 0, "failed": 0, "buf": b""}

def ok(name, cond, detail=""):
    checks["n"] += 1
    if cond:
        print("ok %d - %s" % (checks["n"], name))
    else:
        checks["failed"] += 1
        print("FAIL %d - %s%s" % (checks["n"], name, (": " + detail) if detail else ""))

def read_line(timeout=5.0):
    import time
    end = time.time() + timeout
    while b"\n" not in checks["buf"]:
        left = end - time.time()
        if left <= 0:
            return None
        r, _, _ = select.select([server.stdout.raw], [], [], left)
        if not r:
            return None
        chunk = os.read(server.stdout.raw.fileno(), 65536)
        if not chunk:
            return None
        checks["buf"] += chunk
    line, _, rest = checks["buf"].partition(b"\n")
    checks["buf"] = rest
    return line

def req(obj, expect_reply=True, timeout=5.0):
    os.write(server.stdin.fileno(), (json.dumps(obj) + "\n").encode())
    if not expect_reply:
        return read_line(0.4)
    return read_line(timeout)

def call(name, args, cid):
    return json.loads(req({"jsonrpc": "2.0", "id": cid,
                           "method": "tools/call",
                           "params": {"name": name, "arguments": args}}))

def tool_text(reply):
    return reply["result"]["content"][0]["text"]

def one_shot_tool_texts(binpath, calls):
    """Drive a SECOND server binary (the pinned pre-fix artifact) through the
    same handshake and return one tool reply text per (name, args) call, with
    the SAME stub root (FX_VERB_ROOT=root) the main server under test uses."""
    e = dict(env); e["FX_VERB_ROOT"] = root
    p = subprocess.Popen([binpath], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, env=e)
    def wr(o):
        p.stdin.write((json.dumps(o) + "\n").encode()); p.stdin.flush()
        return json.loads(p.stdout.readline())
    wr({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
    p.stdin.write((json.dumps({"jsonrpc": "2.0",
                               "method": "notifications/initialized",
                               "params": {}}) + "\n").encode()); p.stdin.flush()
    out = []
    for i, (name, args) in enumerate(calls):
        r = wr({"jsonrpc": "2.0", "id": 10 + i, "method": "tools/call",
                "params": {"name": name, "arguments": args}})
        out.append(r["result"]["content"][0]["text"])
    p.stdin.close(); p.wait(timeout=5)
    return out

# 1 — handshake
r = req({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
d = json.loads(r)
ok("initialize handshake", d["result"]["protocolVersion"] == "2025-06-18"
   and d["result"]["serverInfo"]["name"] == "fx-verbs"
   and d["id"] == 1, r)

# 2 — notifications/initialized is silent
r = req({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}},
        expect_reply=False)
ok("notifications/initialized is silent", r is None, repr(r))

# 3 — tools/list: the whole verb table, in order
r = req({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
d = json.loads(r)
tools = d["result"]["tools"]
want = ["fx_query", "fx_status", "fx_activate", "fx_rollback", "fx_what",
        "fx_why", "fx_store_verify", "fx_build", "fx_outcome", "fx_generation",
        "fx_read", "fx_write", "fx_ls"]
got = [t["name"] for t in tools]
ok("tools/list advertises the 13 verbs in order", got == want, repr(got))
ok("every tool has a non-empty description",
   all(t.get("description") for t in tools))

# 4 — fx_query (exec verb, stub fxctl)
d = call("fx_query", {"relation": "generation"}, 10)
txt = tool_text(d)
ok("fx_query runs fxctl q <rel> under the root",
   txt.startswith("exit=0\n") and "relation:generation" in txt, txt)

# 5 — command resolution: with no bin/fxctl in this root, the lookup falls
# through to usr/fx-core/bin rather than the store-bin decoy
ok("lookup falls through to usr/fx-core/bin over the fx/store/bin decoy",
   "DECOY" not in txt, txt)

# 6-9 — the other exec verbs
d = call("fx_status", {}, 11)
ok("fx_status", "gen 42 current" in tool_text(d), tool_text(d))

# 6a — fx_activate over a REAL control-channel fixture: a fake PID1 speaking
# the documented fifo line protocol (the pair <root>/run/fx/control.in +
# control.out; a request `activate <config>\n' on control.in; data lines then
# OK on control.out).  This is PID1's own protocol (init.zig setup_fifo_ctrl /
# handle_fifo), not a mock of this server — a stub that only echoed would
# prove nothing about the wire grammar.  The fake parks its fds O_RDWR
# exactly like PID1 (a fifo write-open with no reader is ENXIO).
runfx = os.path.join(root, "run", "fx")
os.makedirs(runfx, exist_ok=True)
ctrl_in = os.path.join(runfx, "control.in")
ctrl_out = os.path.join(runfx, "control.out")
os.mkfifo(ctrl_in, 0o600)
os.mkfifo(ctrl_out, 0o600)
fake_log = os.path.join(root, "fake-pid1.log")
fake = subprocess.Popen(["python3", "-c", r'''
import os, sys, time
cin, cout, log = sys.argv[1], sys.argv[2], sys.argv[3]
# PID1's own shape: both ends O_RDWR|O_NONBLOCK — a parked reader on
# control.in (a client's O_WRONLY open can never ENXIO) and a parked
# writer on control.out (a client's read never EOFs when PID1 lives).
fdi = os.open(cin, os.O_RDWR | os.O_NONBLOCK)
fdo = os.open(cout, os.O_RDWR | os.O_NONBLOCK)
n = 0
with open(log, "w") as lg:
    lg.write("ready\n"); lg.flush()
    while True:
        try:
            b = os.read(fdi, 4096)
        except BlockingIOError:
            time.sleep(0.01); continue
        if not b:
            time.sleep(0.01); continue
        for line in b.decode("latin1").split("\n"):
            if not line.strip():
                continue
            n += 1
            lg.write("req %d: %s\n" % (n, line)); lg.flush()
            if n == 1:
                # the success shape: PID1's data line then OK
                os.write(fdo, b"activated version 9\nOK\n")
            elif n == 2:
                # the refusal shape: PID1's VERBATIM service-table overflow
                # refusal (init.zig's format string — the smoke must speak the
                # real protocol text, not an invented paraphrase)
                os.write(fdo, b"ERR activated version 10 but REFUSED: service "
                               b"'wide' is #65, window 64, 1 rows past it\n")
            else:
                os.write(fdo, b"ERR unknown command\n")
''', ctrl_in, ctrl_out, fake_log])
def wait_fake(nreq):
    # nreq == 0 waits only for the fake's fds to be parked ("ready")
    for _ in range(500):
        try:
            t = open(fake_log).read()
            if t.count("req ") >= nreq and (nreq > 0 or "ready" in t):
                return t
        except OSError:
            pass
        time.sleep(0.02)
    return ""
wait_fake(0)  # the fake must hold its reader BEFORE the first request
d = call("fx_activate", {"config": "/fx/disk/agent-config.dhall"}, 70)
txt = tool_text(d)
ok("fx_activate THROUGH PID1's channel: PID1's reply line reaches the model, exit=0",
   txt.startswith("exit=0\n") and "activated version 9" in txt, txt)
ok("fx_activate channel: the request line is exactly `activate <config>'",
   "req 1: activate /fx/disk/agent-config.dhall" in wait_fake(1), txt)
# THE REFUSAL PATH: PID1's ERR must surface as LOUD text + exit=1 — the
# service-table overflow refusal is the diagnosis the model acts on.
d = call("fx_activate", {"config": "/fx/disk/agent-config.dhall"}, 71)
txt = tool_text(d)
ok("fx_activate channel: PID1's REFUSAL is loud, verbatim, exit=1",
   txt.startswith("exit=1\n") and "ERR activated version 10 but REFUSED" in txt
   and "is #65, window 64," in txt, txt)
# a config path with whitespace is refused BEFORE the channel (PID1's grammar
# is space/tab-delimited with no quoting — such a path cannot be carried)
d = call("fx_activate", {"config": "/fx/disk/agent bad.dhall"}, 72)
txt = tool_text(d)
ok("fx_activate: a whitespace config path is refused before the channel",
   txt.startswith("exit=1\n") and "fx_activate REFUSED" in txt
   and "whitespace" in txt, txt)
ok("fx_activate: the whitespace refusal never reached PID1 "
   "(no third request logged)",
   wait_fake(2).count("req ") == 2, txt)
fake.terminate(); fake.wait(timeout=5)

# 6b — the CHANNEL-LESS fallback: with the pair gone (fake PID1 dead, fifos
# removed), fx_activate execs the root's /bin/fx-activate directly — the OLD
# route — and the reply's FIRST line is the LOUD reduced-semantics banner:
# published, NOT committed.  A silent downgrade is the failure this catches.
os.unlink(ctrl_in)
os.unlink(ctrl_out)
d = call("fx_activate", {"config": "/fx/disk/agent-config.dhall"}, 12)
txt = tool_text(d)
ok("fx_activate with NO channel: direct-exec fallback with a LOUD banner",
   txt.startswith("exit=0\n") and
   "NO PID1 CONTROL CHANNEL" in txt and
   "REDUCED semantics" in txt and
   "PUBLISHED" in txt and "NOT COMMITTED" in txt, txt)
ok("fx_activate fallback: the pinned argv is intact (guest store + frozen pkgset)",
   "RUNBIN fx-activate args: --store /fx/disk/store --package-set "
   "/usr/fx/package-set.dhall --config /fx/disk/agent-config.dhall" in txt, txt)
# THE MARKER'S STRUCTURAL EXCLUSION, and the .operator exclusion the
# runtime-record closure turns on TWO conditions:
#   (i) the whitelist: the marker planted in the SERVER's env (above) must
#       NOT reach the fallback child.  The stub fx-activate dumps `env` into
#       $ROOT/envdump, so this is measured on the child, not asserted about
#       the code; the same dict's RATTAN_*/LD_* keys are the probe's control
#       (12 asserts those dropped for a sibling verb's child).
#   (ii) the no-nonce half of the predicate is proven by the OFFLINE gates
#       (fx-init's activate_diff.sh / prov_e2e.sh / qemu_activate.sh run
#       fx-activate directly on the HOST's kernel command line, which carries
#       no fx.bootnonce=) and by fx-init's qemu_svc_refuse.sh nonce-less
#       in-guest direct exec.  A host-side stub cannot reach the publish
#       step (the pinned argv names the GUEST's /fx/disk/store and
#       /usr/fx/package-set.dhall), so what is pinned HERE is the fallback
#       PLUMBING and that the server itself is not a journal writer.
fenv = open(os.path.join(root, "envdump")).read().splitlines()
fkeys = set(l.split("=", 1)[0] for l in fenv if "=" in l)
ok("fx_activate fallback: the handler's marker does NOT leak into the direct "
   "exec (SAME dump keeps the whitelist live: the planted RATTAN_*/LD_* are "
   "dropped too)",
   "FX_OPERATOR_RECORDED" not in fkeys
   and not any(k.startswith("RATTAN_") or k.startswith("LD_") for k in fkeys),
   repr(sorted(fkeys)))
if "fx.bootnonce=" in open("/proc/cmdline").read():
    print("skip - the .operator exclusion arm: this HOST's own /proc/cmdline "
          "carries fx.bootnonce=, so a host-side fx-activate would self-record "
          "and the no-nonce exclusion cannot be measured here")
else:
    ok("fx_activate fallback: the pinned store gains NO .operator from the exec",
       not os.path.exists(os.path.join(root, "fx/disk/store/.operator")),
       "the server (or its stub target) wrote a journal row")
# the mkinitramfs -b STAGED copy is a DIFFERENT binary; it must not shadow the
# running root's.  This check FAILS on the pre-2026-10 resolution order.
ok("the staged usr/fx-core/bin copy does NOT shadow the running root's /bin",
   "STAGED-COPY" not in txt, txt)
d = call("fx_rollback", {"version": "7"}, 13)
ok("fx_rollback (string version)", "rolled:7" in tool_text(d), tool_text(d))
d = call("fx_rollback", {"version": 9}, 14)   # the model may send a number
ok("fx_rollback (int version)", "rolled:9" in tool_text(d), tool_text(d))
d = call("fx_what", {"target": "/usr/bin/fxsh"}, 15)
ok("fx_what", "what:/usr/bin/fxsh:install" in tool_text(d), tool_text(d))
d = call("fx_why", {"package": "hello"}, 16)
ok("fx_why", "why:hello closure=2 roots=consh" in tool_text(d), tool_text(d))

# 10/11 — the drift gate: fx_store_verify's exit 1 must reach the model
d = call("fx_store_verify", {}, 17)
txt = tool_text(d)
ok("fx_store_verify audits the LIVE store (fxstore verify --store /fx/disk/store)",
   txt.startswith("exit=0\n") and
   "fxstore args: --store /fx/disk/store" in txt, txt)
open(os.path.join(root, "drift-flag"), "w").write("1\n")
d = call("fx_store_verify", {}, 18)
txt = tool_text(d)
ok("fx_store_verify drift -> exit=1 IS in the reply text (the drift gate)",
   txt.startswith("exit=1\n") and "etc/motd: missing" in txt, txt)
os.unlink(os.path.join(root, "drift-flag"))

# 11d — fx_build, THE IN-GUEST BUILD VERB.  The argv is PINNED (fxstore build
# --store <the guest's own store> <pkg>), the cwd is PINNED (/usr/fx, where
# the image's frozen package set lives), and the package is BOUNDED by the
# host-declared closed set FX_AGENT_BUILDABLE — UNSET here, so the DEFAULT set
# is exactly the one slot package 'oslot' (never "any name").
d = call("fx_build", {"package": "oslot"}, 80)
txt = tool_text(d)
ok("fx_build runs the PINNED argv against the guest's own store",
   txt.startswith("exit=0\n") and
   "build args: --store /fx/disk/store oslot" in txt, txt)
ok("fx_build's cwd is pinned to /usr/fx (the frozen package set's dir)",
   open(os.path.join(root, "builddump")).read().strip() == os.path.join(root, "usr/fx"),
   repr(open(os.path.join(root, "builddump")).read()))
# the bound: a name OUTSIDE the closed set is refused loudly, naming the set;
# a flag- or path-shaped argument is refused as NOT A BARE NAME.  Neither
# refusal reaches fxstore (no stub output).
d = call("fx_build", {"package": "dhake"}, 81)
txt = tool_text(d)
ok("fx_build outside the buildable set -> exit=1, REFUSED, naming the set "
   "(default: the slot package only)",
   txt.startswith("exit=1\n") and "REFUSED" in txt
   and "'dhake'" in txt and "FX_AGENT_BUILDABLE" in txt
   and "build args:" not in txt, txt)
d = call("fx_build", {"package": "--store"}, 82)
txt = tool_text(d)
ok("fx_build with a FLAG-shaped argument -> refused as not a bare package name",
   txt.startswith("exit=1\n") and "REFUSED" in txt
   and "not a bare package name" in txt and "build args:" not in txt, txt)
d = call("fx_build", {"package": "/fx/disk/store"}, 83)
txt = tool_text(d)
ok("fx_build with a PATH-shaped argument -> refused as not a bare package name",
   txt.startswith("exit=1\n") and "REFUSED" in txt
   and "not a bare package name" in txt and "build args:" not in txt, txt)
# the FXSTORE_* seats are injected ONLY when staged under the root: this stub
# root has no usr/fx-agent/bin, so fxstore must see NEITHER key (its own
# defaults hold — host behaviour unchanged).
dump = open(os.path.join(root, "envdump")).read().splitlines()
ok("no FXSTORE_SH/FXSTORE_STAGE3 without staged seats (host default holds)",
   not any(l.startswith("FXSTORE_SH=") or l.startswith("FXSTORE_STAGE3=")
           for l in dump), repr(dump))
# ... and WITH the seats staged, both keys arrive pointing at them (the
# in-guest contract: the pivoted root has no /bin/sh, so fxstore is pointed
# at the deployment's staged interpreter + sandbox binary).
seats = os.path.join(root, "usr/fx-agent/bin")
os.makedirs(seats, exist_ok=True)
for seat in ("sh", "stage3"):
    open(os.path.join(seats, seat), "w").write("#!/bin/sh\nexit 0\n")
    os.chmod(os.path.join(seats, seat), 0o755)
d = call("fx_build", {"package": "oslot"}, 84)
txt = tool_text(d)
ok("fx_build with staged seats -> FXSTORE_SH/FXSTORE_STAGE3 injected",
   txt.startswith("exit=0\n"), txt)
dump = open(os.path.join(root, "envdump")).read().splitlines()
ok("the seats point under the root, executability-gated",
   "FXSTORE_SH=%s" % os.path.join(seats, "sh") in dump
   and "FXSTORE_STAGE3=%s" % os.path.join(seats, "stage3") in dump,
   repr([l for l in dump if l.startswith("FXSTORE_")]))
# (fxstore itself still resolves from usr/fx-core/bin: the seats dir holds no
# fxstore, and the lookup order keeps the generation's own bin first.)
ok("the verb PATH carries the payload dir last of the root's",
   "PATH=%s/bin:%s/usr/fx-core/bin:%s/fx/store/bin:%s/usr/fx-agent/bin:/bin:/usr/bin"
   % (root, root, root, root) in dump,
   repr([l for l in dump if l.startswith("PATH=")]))

# 11b/11c — THE OUTCOME INSTRUMENT: fx_outcome reports the boot history and the
# generation this boot is running; fx_generation reports just the number.  Both
# read the store's OWN plain files (the state planted above is fx-init's real
# disk .bootlog for a FAILED generation, and its .recovery journal for a machine
# that has rolled forward THREE times — the same fault twice).
d = call("fx_outcome", {}, 19)
txt = tool_text(d)
ok("fx_outcome: current generation + the previous boot's verdict + the history",
   txt.startswith("exit=0\n")
   and "store /fx/disk/store\n" in txt
   and "current 7\n" in txt
   and "last 7 failed\n" in txt
   and "boots 6\n" in txt
   and "boot 7 failed 1791556292\n" in txt
   and "boot 3 ok 1791556226\n" in txt, txt)
ok("fx_outcome: the history is in bootlog ORDER, one line per boot",
   txt.index("boot 3 in-progress") < txt.index("boot 3 ok")
   < txt.index("boot 7 in-progress") < txt.index("boot 7 failed"), txt)
# 11b-J — THE RECOVERY JOURNAL, the has-this-happened-before half.  FAILS if
# the verb ignores <store>/.recovery (no recoveries line), counts the '#' header
# or the torn tail (wrong number), loses the last/newest line, claims a
# recurrence without the honesty limit, or hides the torn floor.
ok("fx_outcome: the recovery journal — count, last, recurrence, torn floor",
   "recoveries 3\n" in txt
   and "recovery_last 1791556288 published v8 from v7 genhash "
       "cafef00d0123456789abcdef\n" in txt
   and "recovery_recur deadbeef0123456789abcdefdeadbeef0123456789abcdef"
       " x2 — the SAME fault returning" in txt
   and "not a live-oscillation claim" in txt
   and "recovery_torn 1 line(s) skipped" in txt
   and "the count is a FLOOR" in txt, txt)
ok("fx_outcome: the journal section sits between `last` and the boot history",
   txt.index("last 7 failed\n") < txt.index("recoveries 3\n")
   < txt.index("boot 3 in-progress"), txt)
d = call("fx_generation", {}, 20)
ok("fx_generation: one line, the store's CURRENT",
   tool_text(d) == "exit=0\ncurrent 7\n", repr(tool_text(d)))
# fail-CLOSED: an unreadable CURRENT is reported as such and exits 1 — the verb
# never prints a guessed generation.
cur = os.path.join(root, "fx/disk/store/.db/snapshots/CURRENT")
saved = open(cur).read()
os.unlink(cur)
d = call("fx_outcome", {}, 21)
txt = tool_text(d)
ok("fx_outcome with no CURRENT -> exit=1, UNREADABLE, never a guessed version",
   txt.startswith("exit=1\n") and "current UNREADABLE:" in txt
   and "boot 7 failed" in txt, txt)
d = call("fx_generation", {}, 22)
txt = tool_text(d)
ok("fx_generation with no CURRENT -> exit=1, naming the file",
   txt.startswith("exit=1\n") and "cannot be opened" in txt
   and "current" not in txt.replace("CURRENT", ""), txt)
open(cur, "w").write(saved)

# 12 — the scrubbed verb env (stub dumped `env` at every fxctl call)
dump = open(os.path.join(root, "envdump")).read().splitlines()
keys = set(line.split("=", 1)[0] for line in dump if "=" in line)
ok("verb env drops RATTAN_* and LD_*",
   not any(k.startswith("RATTAN_") or k.startswith("LD_") for k in keys),
   repr(sorted(keys)))
pathline = [l for l in dump if l.startswith("PATH=")]
ok("verb PATH is rooted, running root's bin FIRST",
   bool(pathline) and
   pathline[0] == "PATH=%s/bin:%s/usr/fx-core/bin:%s/fx/store/bin:"
                  "%s/usr/fx-agent/bin:/bin:/usr/bin"
                  % (root, root, root, root),
   repr(pathline))
ok("verb env carries FX_STORE (rooted store)",
   "FX_STORE=%s/fx/store" % root in dump, repr(dump))

# 13/14 — native file verbs, sandboxed under the root
d = call("fx_write", {"path": "/note.txt", "content": "hello fx\n"}, 20)
ok("fx_write", tool_text(d).startswith("exit=0\n"), tool_text(d))
ok("fx_write landed inside the root (sandboxed)",
   open(os.path.join(root, "note.txt")).read() == "hello fx\n"
   and not os.path.exists("/note.txt"))

# 13b — THE WRITABLE SET: fx_write's surface is the host-declared closed set
# (FX_AGENT_WRITABLE).  A path OUTSIDE the set is REFUSED loudly — it exits 1,
# NAMES the path, NAMES the set and says the set is host-declared — and the
# file is neither created nor touched.  The harness's own record path is in NO
# set: a model that could rewrite attempts.jsonl could erase its own failed
# activation and re-issue it blindly (the oscillator the observation loop
# exists to stop).
rec = os.path.join(root, "fx/disk/agent-data/attempts.jsonl")
os.makedirs(os.path.dirname(rec), exist_ok=True)
open(rec, "w").write("PRE-EXISTING RECORD LINE\n")
d = call("fx_write", {"path": "/fx/disk/agent-data/attempts.jsonl",
                      "content": "FORGED-RECORD-LINE"}, 70)
txt = tool_text(d)
ok("fx_write outside the writable set -> exit=1, REFUSED, naming path + set "
   "+ host-declared",
   txt.startswith("exit=1\n") and "REFUSED" in txt
   and "/fx/disk/agent-data/attempts.jsonl" in txt
   and "FX_AGENT_WRITABLE" in txt and "host-declared" in txt, txt)
ok("the refused write left the record file untouched",
   open(rec).read() == "PRE-EXISTING RECORD LINE\n", repr(open(rec).read()))
# the membership check runs on the CANONICALIZED path, so a '..' spelling of
# the record path cannot reach around the set
d = call("fx_write", {"path": "/note.txt/../fx/disk/agent-data/attempts.jsonl",
                      "content": "FORGED-RECORD-LINE"}, 71)
txt = tool_text(d)
ok("fx_write via a '..' spelling of a non-set path -> still REFUSED",
   txt.startswith("exit=1\n") and "REFUSED" in txt, txt)
ok("the traversal write did not land either",
   open(rec).read() == "PRE-EXISTING RECORD LINE\n", repr(open(rec).read()))
# a symlink at the final path must not redirect an allowed write: /note-link
# IS in the writable set, so the set gate passes and open() itself must refuse
# (O_NOFOLLOW — a pre-planted symlink must not redirect a granted write at
# the record, or any other file)
os.symlink(rec, os.path.join(root, "note-link"))
d = call("fx_write", {"path": "/note-link", "content": "x"}, 72)
txt = tool_text(d)
ok("fx_write through a symlink at the final path -> refused at open (O_NOFOLLOW)",
   txt.startswith("exit=1\n") and "cannot create" in txt, txt)
ok("the symlinked record file was not redirected",
   open(rec).read() == "PRE-EXISTING RECORD LINE\n", repr(open(rec).read()))
os.unlink(os.path.join(root, "note-link"))

d = call("fx_read", {"path": "/note.txt"}, 21)
ok("fx_read round-trips", tool_text(d) == "exit=0\nhello fx\n", repr(tool_text(d)))

# 13c — THE DOCUMENTED ENTRY SPELLING grants, and grants ONLY what it names.
# The comments and the model-facing description say entries are root-relative;
# a relative entry (fx/rel-note.txt) must match the ABSOLUTE request
# /fx/rel-note.txt (a deployment following the docs must not get a silently
# empty set), and the normalization must not widen: a RELATIVE request is
# still refused, and a relative entry cannot spell anything outside the root.
d = call("fx_write", {"path": "/fx/rel-note.txt", "content": "rel entry\n"}, 40)
ok("a ROOT-RELATIVE set entry matches an absolute request (docs spelling)",
   tool_text(d).startswith("exit=0\n")
   and open(os.path.join(root, "fx/rel-note.txt")).read() == "rel entry\n",
   tool_text(d))
d = call("fx_write", {"path": "fx/rel-note.txt", "content": "nope"}, 41)
ok("a RELATIVE request is still refused (only the ENTRY is normalized)",
   tool_text(d).startswith("exit=1\n") and "REFUSED" in tool_text(d),
   tool_text(d))
d = call("fx_write", {"path": "/fx/other.txt", "content": "nope"}, 42)
ok("the relative entry granted nothing beside the one file it names",
   tool_text(d).startswith("exit=1\n") and "REFUSED" in tool_text(d)
   and not os.path.exists(os.path.join(root, "fx/other.txt")), tool_text(d))

# 13d — THE ALLOWED '..' DIRECTION: a '..' spelling that canonicalizes ONTO
# an allowed member must still WRITE (an over-refusing regression — e.g.
# refusing any path that merely contains '..' — would pass every other
# committed probe, which all pin the REFUSED direction only).
d = call("fx_write", {"path": "/fx/../note.txt", "content": "dotdot allowed\n"}, 43)
ok("a '..' spelling ONTO an allowed member still writes",
   tool_text(d).startswith("exit=0\n")
   and open(os.path.join(root, "note.txt")).read() == "dotdot allowed\n",
   tool_text(d))

d = call("fx_read", {"path": "/nope"}, 22)
ok("fx_read of a missing file -> exit=1 + message",
   tool_text(d).startswith("exit=1\n") and "cannot open" in tool_text(d),
   tool_text(d))

# 13e — THE READ/LIST ROOT BOUND: a '..' that CLIMBS ABOVE FX_VERB_ROOT must
# be REFUSED (exit=1, naming the path and the root) and the host file outside
# the root must NOT come back.  Before the fix, native_read/native_ls
# root_join'd the request raw, so these requests returned HOST bytes — the
# escape is made VISIBLE by planting a known secret just outside $ROOT.
# THE BOUND IS "cannot climb above the root", NOT "no '..'": the ALLOWED arms
# below (13f) pin the direction a naive "refuse any '..'" regression fails.
climb1 = "/" + os.path.relpath(outside, root)                 # ../<outside>
climb2 = "/" + os.path.relpath("/", root) + os.path.relpath(outside, "/")
secret = open(os.path.join(outside, "secret.txt")).read()
d = call("fx_read", {"path": climb1 + "/secret.txt"}, 25)
txt = tool_text(d)
ok("fx_read via a '..' above the root -> exit=1, REFUSED, naming the root",
   txt.startswith("exit=1\n") and "REFUSED" in txt and "FX_VERB_ROOT" in txt
   and root in txt, txt)
ok("the refused read returned NO host bytes",
   "HOST-SECRET" not in txt, txt)
d = call("fx_read", {"path": climb2 + "/secret.txt"}, 26)
txt = tool_text(d)
ok("fx_read via a DEEPER '..' chain (climb out of / and back) -> REFUSED too",
   txt.startswith("exit=1\n") and "REFUSED" in txt and "HOST-SECRET" not in txt,
   txt)
d = call("fx_ls", {"path": climb1}, 27)
txt = tool_text(d)
ok("fx_ls via a '..' above the root -> exit=1, REFUSED, naming the root",
   txt.startswith("exit=1\n") and "REFUSED" in txt and root in txt, txt)
ok("the refused ls listed nothing outside the root",
   "secret.txt" not in txt and "hostdir" not in txt, txt)
# a RELATIVE path is not addressed under the root either (native_write's
# non-absolute case, mirrored): the bound is a path gate, and a relative
# spelling is not a path under FX_VERB_ROOT.
d = call("fx_read", {"path": "note.txt"}, 28)
txt = tool_text(d)
ok("fx_read of a RELATIVE path -> REFUSED (paths are absolute under the root)",
   txt.startswith("exit=1\n") and "REFUSED" in txt, txt)
d = call("fx_ls", {"path": "fx"}, 29)
txt = tool_text(d)
ok("fx_ls of a RELATIVE path -> REFUSED", txt.startswith("exit=1\n")
   and "REFUSED" in txt, txt)

# 13f — THE ALLOWED '..' DIRECTION (the over-refusal guard, mirroring 13d): a
# '..' that canonicalizes to a point still INSIDE the root must still READ and
# LIST.  A regression that refuses any path containing '..' passes every
# REFUSED arm above and fails exactly here.
d = call("fx_read", {"path": "/fx/../note.txt"}, 44)
ok("a '..' spelling INSIDE the root still reads",
   tool_text(d) == "exit=0\ndotdot allowed\n", repr(tool_text(d)))
d_dotdot = call("fx_ls", {"path": "/fx/.."}, 45)
d_root = call("fx_ls", {"path": "/"}, 46)
ok("a '..' spelling INSIDE the root still lists (the root itself)",
   tool_text(d_dotdot).startswith("exit=0\n")
   and tool_text(d_dotdot) == tool_text(d_root)
   and "note.txt" in tool_text(d_dotdot), repr(tool_text(d_dotdot)))

# 13g — THE ASYMMETRY, RUN: the PINNED PRE-FIX server gets the SAME escaping
# requests against the SAME stub root, and they SUCCEED there (host bytes
# returned / the outside dir listed).  A fix proven only post-fix is a fix on
# trust; this is the fail-before half.
if pre_bin:
    pre_read, pre_ls = one_shot_tool_texts(
        pre_bin, [("fx_read", {"path": climb1 + "/secret.txt"}),
                  ("fx_ls", {"path": climb1})])
    ok("ASYMMETRY pre-fix: the same '..' read SUCCEEDED and returned host bytes",
       pre_read.startswith("exit=0\n") and secret.strip() in pre_read,
       repr(pre_read))
    ok("ASYMMETRY pre-fix: the same '..' ls listed the host dir outside the root",
       pre_ls.startswith("exit=0\n") and "secret.txt" in pre_ls, repr(pre_ls))
else:
    sys.stderr.write("verbs-smoke: SKIP (root-bound asymmetry): no pinned pre-fix "
                     "server was built — the fail-before half did NOT run\n")

# 15/16 — fx_ls, explicit and default
d = call("fx_ls", {"path": "/"}, 23)
ls = tool_text(d)
ok("fx_ls lists the root with dirs suffixed /",
   ls.startswith("exit=0\n") and "fx/\n" in ls and "usr/\n" in ls
   and "note.txt\n" in ls, repr(ls))
d = call("fx_ls", {}, 24)
ok("fx_ls default path is the root itself", tool_text(d) == ls, repr(tool_text(d)))

# 17 — unknown tool: JSON-RPC error, and the server LIVES
d = call("no_such_verb", {}, 30)
ok("unknown tool -> -32602 error, not a crash",
   d.get("error", {}).get("code") == -32602, repr(d))
d = call("fx_status", {}, 31)
ok("server answers after an unknown-tool error",
   "gen 42 current" in tool_text(d), repr(d))

# 18 — unknown METHOD -> -32601
r = req({"jsonrpc": "2.0", "id": 32, "method": "resources/list", "params": {}})
d = json.loads(r)
ok("unknown method -> -32601", d["error"]["code"] == -32601, r)

# 19 — missing/invalid argument -> -32602
d = call("fx_query", {}, 33)
ok("fx_query without relation -> -32602",
   d.get("error", {}).get("code") == -32602, repr(d))

# 20 — malformed line -> -32700, server survives
os.write(server.stdin.fileno(), b"this is not json\n")
d = json.loads(read_line())
ok("malformed frame -> -32700", d["error"]["code"] == -32700, repr(d))
d = call("fx_status", {}, 34)
ok("server answers after a malformed frame",
   "gen 42 current" in tool_text(d), repr(d))

# 21 — oversize line (cap = 1 MiB, the client's MCP_MAX_LINE) -> -32700
os.write(server.stdin.fileno(), b"x" * (1024 * 1024 + 64) + b"\n")
d = json.loads(read_line())
ok("oversize line -> -32700 cap error", d["error"]["code"] == -32700, repr(d))
d = call("fx_status", {}, 35)
ok("server answers after an oversize line",
   "gen 42 current" in tool_text(d), repr(d))

# 22 — ping; 23 — string id echoed verbatim
r = req({"jsonrpc": "2.0", "id": 40, "method": "ping", "params": {}})
ok("ping -> result {}", json.loads(r)["result"] == {}, r)
r = req({"jsonrpc": "2.0", "id": "abc-42", "method": "ping", "params": {}})
ok("string id echoed", json.loads(r)["id"] == "abc-42", r)

# 24 — unknown NOTIFICATION is silent
r = req({"jsonrpc": "2.0", "method": "foo/bar", "params": {}}, expect_reply=False)
ok("unknown notification is silent", r is None, repr(r))

# 25/26 — BURST: several frames in one write must ALL be answered, in order
# (frames coalesce in the pipe; each coalesced frame once got dropped)
burst = "".join(json.dumps(o) + "\n" for o in [
    {"jsonrpc": "2.0", "id": 50, "method": "ping", "params": {}},
    {"jsonrpc": "2.0", "id": 51, "method": "tools/call",
     "params": {"name": "fx_query", "arguments": {"relation": "svc"}}},
    {"jsonrpc": "2.0", "id": 52, "method": "ping", "params": {}},
])
os.write(server.stdin.fileno(), burst.encode())
d1 = json.loads(read_line())
d2 = json.loads(read_line())
d3 = json.loads(read_line())
ok("burst: all three coalesced frames answered, ids intact",
   d1["id"] == 50 and d2["id"] == 51 and d3["id"] == 52
   and "relation:svc" in tool_text(d2), repr((d1, d2, d3)))

server.stdin.close()
rc = server.wait(timeout=5)
ok("clean EOF -> server exit 0", rc == 0, "rc=%s stderr=%r" % (rc, server.stderr.read()))

# ── second instance: a root with NO verbs in it ──────────────────────────────
empty = os.path.join(root, "empty")
os.makedirs(empty, exist_ok=True)
env2 = dict(env); env2["FX_VERB_ROOT"] = empty
s2 = subprocess.Popen([bin], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                      stderr=subprocess.PIPE, env=env2)
def req2(obj):
    os.write(s2.stdin.fileno(), (json.dumps(obj) + "\n").encode())
    return json.loads(s2.stdout.readline())
req2({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
os.write(s2.stdin.fileno(), (json.dumps(
    {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}}) + "\n").encode())
d = req2({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
          "params": {"name": "fx_status", "arguments": {}}})
txt = d["result"]["content"][0]["text"]
ok("missing verb binary -> exit=127 + message, not a crash",
   txt.startswith("exit=127\n") and "fxctl not found under FX_VERB_ROOT" in txt,
   txt)
s2.stdin.close()
s2.wait(timeout=5)

# ── third instance: a DISKLESS-guest root — the verb binaries resolve, but the
#    store the store-scoped rows name (/fx/disk/store, fx-init's g_store, which
#    exists only while the disk store is MOUNTED) does not.  The verb must say
#    so, NAMING the path, instead of exec'ing a stub that fails downstream or
#    silently guessing another store.
nostore = os.path.join(root, "nostore")
os.makedirs(os.path.join(nostore, "usr/fx-core/bin"), exist_ok=True)
for stub in ("fxctl", "fxstore", "fx-activate"):
    shutil.copy(os.path.join(root, "usr/fx-core/bin", stub),
                os.path.join(nostore, "usr/fx-core/bin", stub))
env3 = dict(env); env3["FX_VERB_ROOT"] = nostore
s3 = subprocess.Popen([bin], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                      stderr=subprocess.PIPE, env=env3)
def req3(obj):
    os.write(s3.stdin.fileno(), (json.dumps(obj) + "\n").encode())
    return json.loads(s3.stdout.readline())
req3({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
os.write(s3.stdin.fileno(), (json.dumps(
    {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}}) + "\n").encode())
def call3(name, args, cid):
    d = req3({"jsonrpc": "2.0", "id": cid, "method": "tools/call",
              "params": {"name": name, "arguments": args}})
    return d["result"]["content"][0]["text"]
txt = call3("fx_store_verify", {}, 60)
ok("store-scoped: fx_store_verify with no /fx/disk/store -> exit=1, NAMING the path",
   txt.startswith("exit=1\n") and
   "fx_store_verify is store-scoped: the store /fx/disk/store does not exist "
   "under FX_VERB_ROOT" in txt, txt)
ok("store-scoped: the refusal happens BEFORE the verb runs (no stub output)",
   "fxstore args:" not in txt, txt)
txt = call3("fx_activate", {"config": "/fx/disk/agent-config.dhall"}, 61)
ok("store-scoped: fx_activate refused too (not 'not found', the STORE is the fault)",
   txt.startswith("exit=1\n") and "fx_activate is store-scoped" in txt
   and "not found under FX_VERB_ROOT" not in txt, txt)
# fx_build is store-scoped the same way: it must refuse BEFORE the bound (and
# before any exec) when the store is not mounted — building into a ramfs
# snapshot would be lost on the restart.
txt = call3("fx_build", {"package": "oslot"}, 65)
ok("store-scoped: fx_build with no /fx/disk/store -> exit=1, NAMING the path",
   txt.startswith("exit=1\n") and
   "fx_build is store-scoped: the store /fx/disk/store does not exist "
   "under FX_VERB_ROOT" in txt and "build args:" not in txt, txt)
# the native outcome verbs are store-scoped the same way (they must not report a
# stale bootlog from an initramfs snapshot under some other store)
for _v, _cid in (("fx_outcome", 63), ("fx_generation", 64)):
    txt = call3(_v, {}, _cid)
    ok("store-scoped: %s refused in a store-less root, NAMING the path" % _v,
       txt.startswith("exit=1\n") and "%s is store-scoped" % _v in txt
       and "Fx/disk/store does not exist under FX_VERB_ROOT" not in txt
       and "/fx/disk/store does not exist under FX_VERB_ROOT" in txt, txt)
# ... and the refusal is SCOPED: a row that does not carry the store still runs
# in this very root (so the check cannot pass by failing everything).
txt = call3("fx_what", {"target": "/usr/bin/fxsh"}, 62)
ok("not store-scoped: fx_what still runs in the same store-less root",
   txt.startswith("exit=0\n") and "what:/usr/bin/fxsh:install" in txt, txt)
s3.stdin.close()
s3.wait(timeout=5)

# ── fourth instance: FX_AGENT_WRITABLE UNSET — the DEFAULT set ───────────────
# The default is the ONE path this harness's own deployment contract tells the
# agent to write (/fx/disk/agent-config.dhall), NEVER "unrestricted": the
# record, the store, the bootlog and CURRENT are in no default set, so a
# deployment that never sets the variable cannot have its observation loop
# defeated by an fx_write.  Pinned here so the default cannot silently drift
# back toward "anywhere under the root" (which is where the review measured
# the hole).
env4 = dict(env); del env4["FX_AGENT_WRITABLE"]
s4 = subprocess.Popen([bin], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                      stderr=subprocess.PIPE, env=env4)
def req4(obj):
    os.write(s4.stdin.fileno(), (json.dumps(obj) + "\n").encode())
    return json.loads(s4.stdout.readline())
req4({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
os.write(s4.stdin.fileno(), (json.dumps(
    {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}}) + "\n").encode())
def call4(name, args, cid):
    d = req4({"jsonrpc": "2.0", "id": cid, "method": "tools/call",
              "params": {"name": name, "arguments": args}})
    return d["result"]["content"][0]["text"]
txt = call4("fx_write", {"path": "/fx/disk/agent-config.dhall", "content": "let x = 1 in x\n"}, 80)
ok("default set (FX_AGENT_WRITABLE unset): the task config path is writable",
   txt.startswith("exit=0\n")
   and open(os.path.join(root, "fx/disk/agent-config.dhall")).read() == "let x = 1 in x\n",
   txt)
txt = call4("fx_write", {"path": "/note.txt", "content": "nope"}, 81)
ok("default set: NOTHING ELSE is writable (the smoke's own /note.txt refused)",
   txt.startswith("exit=1\n") and "REFUSED" in txt
   and "FX_AGENT_WRITABLE" in txt, txt)
ok("default set: the refusal NAMES the default it fell back to",
   "/fx/disk/agent-config.dhall" in txt, txt)
ok("default set: the refused write did not touch /note.txt",
   open(os.path.join(root, "note.txt")).read() == "dotdot allowed\n",
   repr(open(os.path.join(root, "note.txt")).read()))
s4.stdin.close()
s4.wait(timeout=5)

# ── fifth instance family: THE OPERATOR POLICY SEAT (ops-policy, S2) ─────────
# The seat loads <root>/usr/fx-agent/policy/{ops-policy.dl,ops-aliases.tsv,
# ops-lexicon.ini,PINS} at startup, verifies every pinned sha256, resolves the
# alias table against the paths it SERVES, and consults the compiled rules at
# the fx_write commit site — AFTER the floor passes, BEFORE open().  Each arm
# names its failure direction; the mutants are the OPERATOR'S OWN re-pinned
# edits, so no pin check can mask them.
import hashlib

POL_SRC = os.path.join(os.getcwd(), "policy", "ops")
POL_FILES = ("ops-policy.dl", "ops-aliases.tsv", "ops-lexicon.ini", "PINS")
REPO_DL_SHA = [l.split("\t")[1].strip()
               for l in open(os.path.join(POL_SRC, "PINS")).read().splitlines()
               if l.startswith("ops-policy.dl\t")][0]
# BOTH writable paths are covered by the REAL pinned table (Agentconfig exact,
# Agentdata exact-on-the-node): the config path is PROTECTED (D1), the data
# node is not — the two shapes the two rules distinguish.
POL_WRITABLE = "/fx/disk/agent-config.dhall:/fx/disk/agent-data"

def build_policy_root(tag, boot, with_policy=True, mutate=None):
    r = os.path.join(root, "pol-" + tag)
    pol = os.path.join(r, "usr/fx-agent/policy")
    if with_policy:
        os.makedirs(pol)
        for f in POL_FILES:
            shutil.copy(os.path.join(POL_SRC, f), os.path.join(pol, f))
    os.makedirs(os.path.join(r, "fx/disk/store/.db/snapshots"))
    with open(os.path.join(r, "fx/disk/store/.db/snapshots/CURRENT"), "w") as fh:
        fh.write("5\n")
    if boot is not None:
        with open(os.path.join(r, "fx/disk/store/.bootlog"), "w") as fh:
            fh.write("5 %s 1791556274\n" % boot)
    if mutate:
        mutate(pol)
    return r

def repin(pol, name):
    sha = hashlib.sha256(open(os.path.join(pol, name), "rb").read()).hexdigest()
    pins_path = os.path.join(pol, "PINS")
    out = []
    for ln in open(pins_path).read().splitlines(True):
        out.append("%s\t%s\n" % (name, sha) if ln.startswith(name + "\t") else ln)
    open(pins_path, "w").write("".join(out))

class Srv:
    """One spawned server against its own policy root (the instance pattern
    above, wrapped: the policy load happens before the loop, and a REFUSING
    server never answers the handshake)."""
    def __init__(self, binpath, proot, writable):
        e = dict(env)
        e["FX_VERB_ROOT"] = proot
        e["FX_AGENT_WRITABLE"] = writable
        self.p = subprocess.Popen([binpath], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  env=e)
        self.buf = b""
        self.init = None  # the initialize reply, set by handshake()
    def read_line(self, timeout=30.0):
        end = time.time() + timeout
        while b"\n" not in self.buf:
            left = end - time.time()
            if left <= 0: return None
            r, _, _ = select.select([self.p.stdout.raw], [], [], left)
            if not r: return None
            chunk = os.read(self.p.stdout.raw.fileno(), 65536)
            if not chunk: return None
            self.buf += chunk
        line, _, rest = self.buf.partition(b"\n")
        self.buf = rest
        return line
    def handshake(self):
        self.p.stdin.write((json.dumps({"jsonrpc": "2.0", "id": 1,
            "method": "initialize", "params": {}}) + "\n").encode())
        self.p.stdin.flush()
        ln = self.read_line()
        self.init = json.loads(ln) if ln is not None else None
        good = ln is not None and self.init is not None and self.init.get("id") == 1
        try:
            self.p.stdin.write((json.dumps({"jsonrpc": "2.0",
                "method": "notifications/initialized",
                "params": {}}) + "\n").encode())
            self.p.stdin.flush()
        except (BrokenPipeError, OSError):
            pass  # a server that REFUSED startup is already dead; that is
                  # the answer the pin/alias arms are reading
        return good
    def text(self, name, args, cid):
        try:
            self.p.stdin.write((json.dumps({"jsonrpc": "2.0", "id": cid,
                "method": "tools/call", "params": {"name": name,
                "arguments": args}}) + "\n").encode())
            self.p.stdin.flush()
        except (BrokenPipeError, OSError):
            return ""  # a dead server fails its arm cleanly, never crashes
        ln = self.read_line()
        if ln is None: return ""
        return json.loads(ln)["result"]["content"][0]["text"]
    def close(self):
        try: self.p.stdin.close()
        except Exception: pass
        rc = self.p.wait(timeout=15)
        return rc, self.p.stderr.read().decode("latin1")

# P1 — THE FLOOR, byte-identical.  A root with NO policy dir is the named
# floor-only state: the floor refusal is unchanged, the set's own member
# still writes (no over-refusal), and the startup line NAMES the state.
bare = build_policy_root("bare", "failed", with_policy=False)
s1 = Srv(bin, bare, POL_WRITABLE); s1.handshake()
t = s1.text("fx_write", {"path": "/fx/disk/nope.txt", "content": "x"}, 100)
ok("P1 floor-only: the floor refusal is unchanged by the policy seat",
   t.startswith("exit=1\nfx-verbs: fx_write REFUSED: ")
   and "is not in the host-declared writable set FX_AGENT_WRITABLE='" in t
   and "host-declared" in t and "ops-policy" not in t and "rule D" not in t,
   repr(t))
if pre_ops_bin:
    pre1 = Srv(pre_ops_bin, bare, POL_WRITABLE); pre1.handshake()
    pt = pre1.text("fx_write", {"path": "/fx/disk/nope.txt", "content": "x"}, 100)
    ok("P1 floor-only: BYTE-IDENTICAL to the pre-seat server on the same request",
       pt == t, repr((t, pt)))
    pre1.close()
else:
    sys.stderr.write("verbs-smoke: SKIP (P1 byte-identical): no pre-seat server\n")
t2 = s1.text("fx_write", {"path": "/fx/disk/agent-data", "content": "x"}, 101)
ok("P1 floor-only: the set's own member still writes (no over-refusal)",
   t2.startswith("exit=0\n"), repr(t2))
rc, err = s1.close()
ok("P1 floor-only: the ABSENT policy dir is the NAMED state, said once",
   "no operator policy at" in err and "floor-only mode" in err
   and "pol-bare/usr/fx-agent/policy" in err, repr(err))

# P0 — THE ASYMMETRY: the policy-deny case (protected path + boot-not-ok,
# BOTH inside the writable set so the FLOOR passes) succeeds pre-change and
# is REFUSED naming rule D2 post-change.  Plus P2: the refusal carries the
# RULE NAME and the DERIVATION (the artifact's own rule text) for every
# fired rule.
deny_root = build_policy_root("deny", "failed")
if pre_ops_bin:
    pre0 = Srv(pre_ops_bin, deny_root, POL_WRITABLE); pre0.handshake()
    pt = pre0.text("fx_write", {"path": "/fx/disk/agent-config.dhall",
                                "content": "x"}, 110)
    ok("P0 ASYMMETRY fail-before: the SAME protected+boot-not-ok write SUCCEEDED "
       "on the pre-seat server (the floor alone governed)",
       pt is not None and pt.startswith("exit=0\n") and "wrote" in pt, repr(pt))
    pre0.close()
    # clear the pre-seat write so the post arm's no-file claim is its own
    os.unlink(os.path.join(deny_root, "fx/disk/agent-config.dhall"))
else:
    sys.stderr.write("verbs-smoke: SKIP (ops-policy P0 fail-before): no pre-seat "
                     "server was built — the asymmetry half did NOT run\n")
sp0 = Srv(bin, deny_root, POL_WRITABLE); sp0.handshake()
dt = sp0.text("fx_write", {"path": "/fx/disk/agent-config.dhall",
                           "content": "x"}, 111)
ok("P0/P2 deny direction: REFUSED naming rule D1 AND rule D2, each with the "
   "artifact's own derivation, the verb, the path and the boot verdict",
   dt.startswith("exit=1\n") and "REFUSED" in dt
   and "policy ops-policy rule D1" in dt and "policy ops-policy rule D2" in dt
   and "protected(C1)" in dt and "!boot_verdict(ok)" in dt
   and "boot verdict not ok" in dt
   and "path /fx/disk/agent-config.dhall" in dt
   and "(verb fx_write" in dt, repr(dt))
rc, err = sp0.close()
ok("P0: the denial lines also reach stderr (the stand-alone console copy)",
   err.count("policy ops-policy rule D") >= 2, repr(err[:400]))
ok("P0: the denied write never reached the filesystem (refused BEFORE open())",
   not os.path.exists(os.path.join(deny_root, "fx/disk/agent-config.dhall")))

# P2-allow side + P3 — the over-refusal guard on the REAL pinned table: the
# ok-boot protected write is STILL denied (D1 is unconditional — that is the
# operator's pinned intent), with the attribution naming D1 alone and the
# boot verdict ok; the ok-boot UNPROTECTED covered write SUCCEEDS.
ok_root = build_policy_root("okboot", "ok")
sok = Srv(bin, ok_root, POL_WRITABLE); sok.handshake()
t = sok.text("fx_write", {"path": "/fx/disk/agent-config.dhall",
                          "content": "x"}, 120)
ok("P2 D1-only attribution: the ok-boot protected write names rule D1 alone, "
   "with boot verdict ok",
   t.startswith("exit=1\n") and "rule D1" in t and "rule D2" not in t
   and "boot verdict ok" in t, repr(t))
t3 = sok.text("fx_write", {"path": "/fx/disk/agent-data", "content": "x"}, 121)
ok("P3 over-refusal guard: the ok-boot unprotected covered write SUCCEEDS",
   t3.startswith("exit=0\n") and "wrote" in t3, repr(t3))
rc, err = sok.close()
ok("the loaded startup line names the artifact, rules, rows and served set",
   "ops-policy: loaded" in err and "2 rule(s)" in err and "2 alias row(s)" in err
   and "2 served writable path(s)" in err and REPO_DL_SHA[:16] in err, repr(err))

# THE VERDICT MOVES, per call, within ONE server: the R3 wrong-moment risk —
# the boot verdict is recomputed fresh per call and a denial never LATCHES.
mroot = build_policy_root("move", "failed")
smv = Srv(bin, mroot, POL_WRITABLE); smv.handshake()
a = smv.text("fx_write", {"path": "/fx/disk/agent-data", "content": "x"}, 130)
ok("verdict-moves: the failed-boot unprotected write is denied by D2 alone",
   a.startswith("exit=1\n") and "rule D2" in a and "rule D1" not in a, repr(a))
with open(os.path.join(mroot, "fx/disk/store/.bootlog"), "w") as fh:
    fh.write("5 ok 1791556274\n")
b = smv.text("fx_write", {"path": "/fx/disk/agent-data", "content": "x"}, 131)
ok("verdict-moves: the SAME server, the bootlog now ok, the SAME write "
   "SUCCEEDS (per-call verdict, nothing latched)",
   b is not None and b.startswith("exit=0\n"), repr(b))
with open(os.path.join(mroot, "fx/disk/store/.bootlog"), "w") as fh:
    fh.write("5 failed 1791556274\n")
c = smv.text("fx_write", {"path": "/fx/disk/agent-data", "content": "x"}, 132)
ok("verdict-moves: and it denies again when the verdict moves back",
   c.startswith("exit=1\n") and "rule D2" in c, repr(c))
smv.close()

# P3 — THE SILENT DENY-ALL CATCH: a deny-all mutant the operator re-pins
# themselves must FLIP the P3 success arm, or the guard is decoration.
def mutate_deny_all(pol):
    with open(os.path.join(pol, "ops-policy.dl"), "w") as fh:
        fh.write("denied(W1, P1) :- touches(W1, P1), kind(W1, write), "
                 "writable(P1).\n")
    repin(pol, "ops-policy.dl")
da = build_policy_root("denyall", "ok", mutate=mutate_deny_all)
sda = Srv(bin, da, POL_WRITABLE)
ok("P3-mutant: the re-pinned deny-all artifact loads (a re-pin is a release; "
   "the pin cannot catch the operator's own mutant)", sda.handshake())
t = sda.text("fx_write", {"path": "/fx/disk/agent-data", "content": "x"}, 140)
ok("P3 THE SILENT DENY-ALL CATCH: the deny-all mutant REFUSES the write the "
   "real policy allows — the P3 arm can fail in the deny-all direction",
   t.startswith("exit=1\n") and "REFUSED" in t and "rule D1" in t, repr(t))
sda.close()

# P4a — THE SILENT ALLOW-ALL CATCH, the seam mutation: the PROTECTED alias's
# pattern is changed to a valid path that matches nothing served, and the PIN
# IS RE-TAKEN (the operator's own bad edit — no pin check can catch it).
# The seat must refuse STARTUP loudly: an unresolvable protected alias is
# never silently unmatched.
def mutate_pattern(pol):
    p = os.path.join(pol, "ops-aliases.tsv")
    txt = open(p).read().replace(
        "Agentconfig\tConfigpath\tyes\t/fx/disk/agent-config.dhall",
        "Agentconfig\tConfigpath\tyes\t/fx/disk/never-matches")
    if "never-matches" not in txt:
        raise AssertionError("the P4a tsv sed matched NOTHING")
    open(p, "w").write(txt)
    repin(pol, "ops-aliases.tsv")
p4a = build_policy_root("p4a", "ok", mutate=mutate_pattern)
sp4 = Srv(bin, p4a, POL_WRITABLE)
hsh = sp4.handshake()
rc, err = sp4.close()
ok("P4a THE SILENT ALLOW-ALL CATCH: the re-pinned never-matching protected "
   "alias refuses STARTUP loudly (naming the table, not the pin — the pin "
   "passed)",
   (not hsh) and rc != 0 and "ops-policy REFUSED" in err
   and ("matches NO served writable path" in err
        or "covered by NO alias row" in err)
   and "sha256 mismatch" not in err, repr(err))

# P4b — the mutation that IS silent (the protected FLAG flipped, pin
# re-taken): the P2 denial DISAPPEARS — the ok-boot protected write SUCCEEDS.
# This is the allow-all executed; the paired control is the P2 D1-only arm
# above on the real table, which refuses the same request.
def mutate_unprotect(pol):
    p = os.path.join(pol, "ops-aliases.tsv")
    txt = open(p).read().replace("Agentconfig\tConfigpath\tyes\t",
                                 "Agentconfig\tConfigpath\tno\t")
    if "Agentconfig\tConfigpath\tno\t" not in txt:
        raise AssertionError("the P4b tsv sed matched NOTHING")
    open(p, "w").write(txt)
    repin(pol, "ops-aliases.tsv")
p4b = build_policy_root("p4b", "ok", mutate=mutate_unprotect)
sb4 = Srv(bin, p4b, POL_WRITABLE)
ok("P4b: the flag-flip mutant loads clean (well-formed; re-pinned)",
   sb4.handshake())
t = sb4.text("fx_write", {"path": "/fx/disk/agent-config.dhall",
                          "content": "x"}, 150)
ok("P4b THE DENIAL DISAPPEARS: with D1's protected row silently flipped (pin "
   "re-taken), the ok-boot protected write SUCCEEDS — the paired P2 arm is "
   "what would fail, and does fail, without it",
   t.startswith("exit=0\n"), repr(t))
sb4.close()

# P5 — THE PIN ARMS: a swapped .dl and a missing .dl each refuse startup,
# naming both shas; two identical deployments decide identically.
def mutate_dl_swap(pol):
    with open(os.path.join(pol, "ops-policy.dl"), "w") as fh:
        fh.write("denied(W1, P1) :- touches(W1, P1), kind(W1, write), "
                 "class(P1, C1), protected(C1).\n")
    # deliberately NO repin: a swapped artifact must die on the pin
p5 = build_policy_root("p5mismatch", "ok", mutate=mutate_dl_swap)
s5 = Srv(bin, p5, POL_WRITABLE)
hsh = s5.handshake(); rc, err = s5.close()
ok("P5: a swapped .dl refuses STARTUP naming BOTH shas (pinned and actual)",
   (not hsh) and rc != 0 and "sha256 mismatch" in err
   and REPO_DL_SHA in err and "pinned" in err and "actual" in err, repr(err))
p5b = build_policy_root("p5missing", "ok")
os.unlink(os.path.join(p5b, "usr/fx-agent/policy/ops-policy.dl"))
s5b = Srv(bin, p5b, POL_WRITABLE)
hsh = s5b.handshake(); rc, err = s5b.close()
ok("P5: a MISSING pinned .dl refuses STARTUP naming the file and the pinned "
   "sha",
   (not hsh) and rc != 0 and "MISSING" in err and REPO_DL_SHA in err, repr(err))
d1 = build_policy_root("det1", "failed")
d2 = build_policy_root("det2", "failed")
sa = Srv(bin, d1, POL_WRITABLE); sa.handshake()
sb2 = Srv(bin, d2, POL_WRITABLE); sb2.handshake()
ta = sa.text("fx_write", {"path": "/fx/disk/agent-config.dhall",
                          "content": "x"}, 160)
tb = sb2.text("fx_write", {"path": "/fx/disk/agent-config.dhall",
                           "content": "x"}, 160)
ok("P5 determinism: identical deployments decide identically, byte for byte",
   ta is not None and ta == tb and "rule D2" in ta, repr((ta, tb)))
sa.close(); sb2.close()

# P7 — THE WRONG-MOMENT ARM: a mid-run swap of the .dl is NOT picked up (the
# startup snapshot decides); a restart with the swapped file dies on the pin.
p7 = build_policy_root("p7", "failed")
s7 = Srv(bin, p7, POL_WRITABLE); s7.handshake()
t1 = s7.text("fx_write", {"path": "/fx/disk/agent-config.dhall",
                          "content": "x"}, 170)
with open(os.path.join(p7, "usr/fx-agent/policy/ops-policy.dl"), "w") as fh:
    fh.write("denied(W1, P1) :- touches(W1, P1), kind(W1, write), "
             "writable(P1), !boot_verdict(ok).\n")
t2 = s7.text("fx_write", {"path": "/fx/disk/agent-config.dhall",
                          "content": "x"}, 171)
ok("P7 THE WRONG-MOMENT ARM: a mid-run .dl swap is NOT picked up — the same "
   "request gets the byte-identical startup-snapshot refusal",
   t1 == t2 and "rule D2" in t2, repr((t1, t2)))
s7.close()
s7b = Srv(bin, p7, POL_WRITABLE)
hsh = s7b.handshake(); rc, err = s7b.close()
ok("P7: a RESTART with the swapped file fails on the pin check",
   (not hsh) and rc != 0 and "sha256 mismatch" in err, repr(err))

# ── round 3 (the S2 review's findings F1–F5) ────────────────────────────────
# The /tmp scratch snapshot must precede the FIRST loaded policy spawn (the
# P1 bare root is floor-only and creates none): F3 moved the engine's scratch
# db under the run dir, and this pin is the negative — no fxv-ops-* dir may
# appear in /tmp all run.
TMP_SCRATCH_BEFORE = {n for n in os.listdir("/tmp") if n.startswith("fxv-ops")}

# F2 — the policy STATE rides the initialize reply (serverInfo): the harness
# /dev/null's the server's stderr (mcp_client.c), so the floor-only startup
# line would leave NO durable marker there.  s1 (P1) is the floor-only
# server; sp0 (P0) is a loaded one; both handshook above.
si1 = (s1.init or {}).get("result", {}).get("serverInfo", {})
ok("F2 floor-only: the initialize reply carries opsPolicy=floor-only in "
   "serverInfo — the state is on the channel the deployment keeps",
   si1.get("opsPolicy") == "floor-only" and "opsPolicySha" not in si1,
   repr(si1))
si0 = (sp0.init or {}).get("result", {}).get("serverInfo", {})
ok("F2 loaded: opsPolicy=loaded and opsPolicySha is the FULL pinned .dl sha",
   si0.get("opsPolicy") == "loaded" and si0.get("opsPolicySha") == REPO_DL_SHA,
   repr(si0))

# F3 — the engine scratch db lives under the RUN DIR, not /tmp: the
# landlock-fallback lane unveils the real /tmp rwc, so same-uid recipe code
# could swap a valid-but-empty db in (rows=0 => allow).  /run is unveiled in
# neither lane.
f3root = build_policy_root("f3", "ok")
sf3 = Srv(bin, f3root, POL_WRITABLE); sf3.handshake()
opsdir = os.path.join(f3root, "run", "fx", "ops")
live = sorted(os.listdir(opsdir)) if os.path.isdir(opsdir) else []
ok("F3: the scratch db is created under <root>/run/fx/ops (one ops-* dir "
   "while the server is alive)",
   len(live) == 1 and live[0].startswith("ops-"), repr(live))
rc, err = sf3.close()
ok("F3: the scratch db is removed at the clean exit (the ops dir is empty)",
   os.path.isdir(opsdir) and os.listdir(opsdir) == [], repr(os.listdir(opsdir)))
TMP_SCRATCH_AFTER = {n for n in os.listdir("/tmp") if n.startswith("fxv-ops")}
ok("F3: NO /tmp fxv-ops-* scratch db appeared at any point this run",
   TMP_SCRATCH_AFTER.issubset(TMP_SCRATCH_BEFORE),
   repr((sorted(TMP_SCRATCH_BEFORE), sorted(TMP_SCRATCH_AFTER))))

# F1 — THE FOLDING ARM: a rule in the LEGAL lexer spelling.  The sentence
# fills the pathclass slot with the proper noun the lexicon declares
# ('Configpath'), so le compiles it to the FOLDED dl constant
# class(P1, configpath) — MEASURED pre-fix: the seat injected the RAW tsv
# surface ('Configpath'), the compiled constant matched nothing, and the
# protected write was ALLOWED (a legal policy silently stopped protecting).
# The compile is the real tooling (eval_ops.py --compile-sentence), so the
# rule here is byte-for-byte what le emits.
LE_DIR = os.environ.get("LE_DIR", "")
EVAL_OPS = os.path.join(os.getcwd(), "policy", "ops", "eval_ops.py")
LE_OK = bool(LE_DIR) and os.path.isfile(os.path.join(LE_DIR, "le", "__init__.py"))
F1_DL = None
if LE_OK:
    f1le = os.path.join(root, "fold-sentence.le")
    with open(f1le, "w") as fh:
        fh.write("A verb W1 is denied for a path P1 if the verb touches the "
                 "path and the verb has Write and the path is of "
                 "Configpath.\n")
    r = subprocess.run(["python3", EVAL_OPS, "--compile-sentence",
                        "--policy-lexicon",
                        os.path.join(POL_SRC, "ops-lexicon.ini"),
                        "--sentence", f1le],
                       capture_output=True, text=True,
                       env=dict(env, LE_DIR=LE_DIR))
    if r.returncode != 0:
        sys.stderr.write("verbs-smoke: F1 arm: the LEGAL folded sentence did "
                         "not compile: %s%s\n" % (r.stdout, r.stderr))
    else:
        F1_DL = r.stdout
        ok("P8 THE FOLDING ARM (compile half): le compiles the legal "
           "'pathclass Configpath' sentence to the FOLDED constant "
           "class(P1, configpath)",
           "class(P1, configpath)" in F1_DL and "Configpath" not in F1_DL,
           repr(F1_DL))
else:
    sys.stderr.write("verbs-smoke: SKIP (P8 folding arm): no le checkout "
                     "(set LE_DIR) — the folding proof did NOT run\n")

if F1_DL is not None:
    def mutate_fold(pol):
        with open(os.path.join(pol, "ops-policy.dl"), "w") as fh:
            fh.write(F1_DL)
        repin(pol, "ops-policy.dl")
    fold_root = build_policy_root("fold", "ok", mutate=mutate_fold)
    sfo = Srv(bin, fold_root, POL_WRITABLE); sfo.handshake()
    t = sfo.text("fx_write", {"path": "/fx/disk/agent-config.dhall",
                              "content": "x"}, 180)
    ok("P8 THE FOLDING ARM (fire half): the folded-constant rule FIRES — the "
       "protected write is refused, naming D1 and quoting the compiled "
       "class(P1, configpath)",
       t.startswith("exit=1\n") and "rule D1" in t
       and "class(P1, configpath)" in t, repr(t))
    ok("P8: the denied write never reached the filesystem",
       not os.path.exists(os.path.join(fold_root,
                                       "fx/disk/agent-config.dhall")))
    t = sfo.text("fx_write", {"path": "/fx/disk/agent-data", "content": "x"},
                 181)
    ok("P8 control: the folded-constant rule denies ONLY its class — the "
       "unprotected covered write still succeeds (not a deny-all mutant)",
       t.startswith("exit=0\n") and "wrote" in t, repr(t))
    sfo.close()
else:
    sys.stderr.write("verbs-smoke: SKIP (P8 fire half): no compiled folded "
                     "rule — the folding proof did NOT run\n")

# F5 — the separator and cap cosmetics, both directions armed.
def mutate_crlf(pol):
    p = os.path.join(pol, "ops-aliases.tsv")
    txt = open(p, newline="").read().replace("\n", "\r\n")
    open(p, "w", newline="").write(txt)
    repin(pol, "ops-aliases.tsv")
crlf_root = build_policy_root("crlf", "ok", mutate=mutate_crlf)
scr = Srv(bin, crlf_root, POL_WRITABLE)
ok("F5 CRLF: a CRLF alias table LOADS CLEAN (the trailing CR is stripped, "
   "never folded into the pattern)", scr.handshake())
t = scr.text("fx_write", {"path": "/fx/disk/agent-config.dhall",
                          "content": "x"}, 182)
ok("F5 CRLF: the protected write is still denied under the CRLF table (the "
   "patterns survived the strip)",
   t.startswith("exit=1\n") and "rule D1" in t, repr(t))
scr.close()

def mutate_biglex(pol):
    with open(os.path.join(pol, "ops-lexicon.ini"), "wb") as fh:
        fh.write(b"# over the artifact cap\n")
        fh.write(b"x" * (1024 * 1024 + 100))
    repin(pol, "ops-lexicon.ini")
big_root = build_policy_root("biglex", "ok", mutate=mutate_biglex)
sbg = Srv(bin, big_root, POL_WRITABLE)
hsh = sbg.handshake(); rc, err = sbg.close()
ok("F5 cap: a pinned file OVER the artifact cap refuses NAMING the reason "
   "(File too large), not a bare MISSING",
   (not hsh) and rc != 0 and "MISSING or unreadable" in err
   and "File too large" in err, repr(err[:300]))

if LE_OK:
    bad = os.path.join(root, "bad-aliases.tsv")
    with open(bad, "w") as fh:
        fh.write("Agentconfig\tConfigpath\tyes\t/a//**\n")
    r = subprocess.run(["python3", EVAL_OPS, "--check-aliases",
                        "--policy-lexicon",
                        os.path.join(POL_SRC, "ops-lexicon.ini"),
                        "--aliases", bad],
                       capture_output=True, text=True,
                       env=dict(env, LE_DIR=LE_DIR))
    ok("F5 grammar drift: '/a//**' (a subtree base ending in '/') is "
       "REFUSED by --check-aliases — the pin-time checker states the SAME "
       "two-form grammar the seat enforces at startup",
       r.returncode != 0 and "alias-ambiguous-pattern" in (r.stdout + r.stderr),
       repr((r.stdout + r.stderr)[:300]))
else:
    sys.stderr.write("verbs-smoke: SKIP (F5 grammar-drift arm): no le "
                     "checkout (set LE_DIR)\n")

print("SMOKE: %d checks, %d failed" % (checks["n"], checks["failed"]))
sys.exit(1 if checks["failed"] else 0)
DRIVER
