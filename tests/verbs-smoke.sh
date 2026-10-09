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
# and drives the server over stdin/stdout with newline-delimited JSON-RPC 2.0
# frames, asserting:
#   the MCP handshake and framing (initialize / notifications/initialized
#   silence / tools/list / tools/call / ping / id echo incl. string ids),
#   every verb row of the table (exec verbs via the stubs, fx_read/fx_write/
#   fx_ls natively under $ROOT), the fx_store_verify EXIT-1-on-drift gate
#   surfacing as "exit=1" in the reply text, root-based command resolution
#   (the running root's bin wins; usr/fx-core/bin then beats the store decoy),
#   the STORE-SCOPED refusal (a row carrying /fx/disk/store will not run when
#   that store is absent — it names the path instead of exec'ing a stub that
#   would have failed downstream), the WRITABLE SET (fx_write refuses every
#   path outside the host-declared FX_AGENT_WRITABLE set — including the
#   harness's own record attempts.jsonl, a '..' spelling of it, and a symlink
#   at the final path — while the set's own paths still write; and with the
#   variable UNSET the default set is exactly /fx/disk/agent-config.dhall),
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
trap 'rm -rf "$ROOT"' EXIT

# ── the stub root ────────────────────────────────────────────────────────────
mkdir -p "$ROOT/usr/fx-core/bin" "$ROOT/fx/store/bin" "$ROOT/bin" "$ROOT/fx/disk/store"

cat > "$ROOT/usr/fx-core/bin/fxctl" <<STUB
#!/bin/sh
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
  *) echo "fxstore-stub: unknown \$cmd" >&2; exit 2 ;;
esac
STUB

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
python3 - "$ROOT" "$BIN" <<'DRIVER'
import json, os, select, shutil, subprocess, sys

root = sys.argv[1]
bin = os.path.abspath(sys.argv[2])

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
        "fx_why", "fx_store_verify", "fx_outcome", "fx_generation",
        "fx_read", "fx_write", "fx_ls"]
got = [t["name"] for t in tools]
ok("tools/list advertises the 12 verbs in order", got == want, repr(got))
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
d = call("fx_activate", {"config": "/fx/disk/agent-config.dhall"}, 12)
txt = tool_text(d)
ok("fx_activate runs the RUNNING root's /bin/fx-activate with the guest store "
   "+ frozen pkgset",
   txt.startswith("exit=0\n") and
   "RUNBIN fx-activate args: --store /fx/disk/store --package-set "
   "/usr/fx/package-set.dhall --config /fx/disk/agent-config.dhall" in txt, txt)
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
   pathline[0] == "PATH=%s/bin:%s/usr/fx-core/bin:%s/fx/store/bin:/bin:/usr/bin"
                  % (root, root, root),
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

print("SMOKE: %d checks, %d failed" % (checks["n"], checks["failed"]))
sys.exit(1 if checks["failed"] else 0)
DRIVER
