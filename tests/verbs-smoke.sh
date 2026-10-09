#!/bin/sh
# tests/verbs-smoke.sh — host smoke test for the fx-verbs MCP stdio tool server
# (tools/fx-verbs-server.c, native build).
#
# Builds a stub root ($ROOT) laid out like the guest:
#   $ROOT/usr/fx-core/bin/{fxctl,fxstore}   host shell-script stubs (fixtures
#   $ROOT/fx/store/bin/fxctl (decoy)         only — the server itself never
#                                            uses a shell)
# and drives the server over stdin/stdout with newline-delimited JSON-RPC 2.0
# frames, asserting:
#   the MCP handshake and framing (initialize / notifications/initialized
#   silence / tools/list / tools/call / ping / id echo incl. string ids),
#   every verb row of the table (exec verbs via the stubs, fx_read/fx_write/
#   fx_ls natively under $ROOT), the fx_store_verify EXIT-1-on-drift gate
#   surfacing as "exit=1" in the reply text, root-based command resolution
#   (usr/fx-core/bin wins over the store decoy), the scrubbed child env
#   (RATTAN_*/LD_* absent from the verb's environment), and the failure paths
#   (unknown tool -> JSON-RPC error, not a crash; oversize line -> error and
#   the server survives; verb binary missing -> exit=127).
#
# The guest (musl) build is verified by tools/build.sh; this test runs the
# native build against the stub root.

set -e
cd "$(dirname "$0")/.."

[ -x build/fx-verbs-server ] || tools/build.sh

ROOT=$(mktemp -d /tmp/fxv-smoke.XXXXXX)
trap 'rm -rf "$ROOT"' EXIT

# ── the stub root ────────────────────────────────────────────────────────────
mkdir -p "$ROOT/usr/fx-core/bin" "$ROOT/fx/store/bin"

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

cat > "$ROOT/usr/fx-core/bin/fxstore" <<STUB
#!/bin/sh
cmd="\$1"; shift
case "\$cmd" in
  what)   echo "what:\$1:install" ;;
  why)    echo "why:\$1 closure=2 roots=consh" ;;
  verify)
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
         "$ROOT/fx/store/bin/fxctl"

# ── the driver ───────────────────────────────────────────────────────────────
python3 - "$ROOT" <<'DRIVER'
import json, os, select, subprocess, sys

root = sys.argv[1]
bin = os.path.abspath("build/fx-verbs-server")

env = {
    "PATH": "/usr/bin:/bin",
    "FX_VERB_ROOT": root,
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
        "fx_why", "fx_store_verify", "fx_read", "fx_write", "fx_ls"]
got = [t["name"] for t in tools]
ok("tools/list advertises the 10 verbs in order", got == want, repr(got))
ok("every tool has a non-empty description",
   all(t.get("description") for t in tools))

# 4 — fx_query (exec verb, stub fxctl)
d = call("fx_query", {"relation": "generation"}, 10)
txt = tool_text(d)
ok("fx_query runs fxctl q <rel> under the root",
   txt.startswith("exit=0\n") and "relation:generation" in txt, txt)

# 5 — command resolution: usr/fx-core/bin beats the store-bin decoy
ok("command lookup prefers usr/fx-core/bin over fx/store/bin",
   "DECOY" not in txt, txt)

# 6-9 — the other exec verbs
d = call("fx_status", {}, 11)
ok("fx_status", "gen 42 current" in tool_text(d), tool_text(d))
d = call("fx_activate", {"config": "console"}, 12)
ok("fx_activate", "activated:console" in tool_text(d), tool_text(d))
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
ok("fx_store_verify clean -> exit=0", tool_text(d).startswith("exit=0\n"),
   tool_text(d))
open(os.path.join(root, "drift-flag"), "w").write("1\n")
d = call("fx_store_verify", {}, 18)
txt = tool_text(d)
ok("fx_store_verify drift -> exit=1 IS in the reply text (the drift gate)",
   txt.startswith("exit=1\n") and "etc/motd: missing" in txt, txt)
os.unlink(os.path.join(root, "drift-flag"))

# 12 — the scrubbed verb env (stub dumped `env` at every fxctl call)
dump = open(os.path.join(root, "envdump")).read().splitlines()
keys = set(line.split("=", 1)[0] for line in dump if "=" in line)
ok("verb env drops RATTAN_* and LD_*",
   not any(k.startswith("RATTAN_") or k.startswith("LD_") for k in keys),
   repr(sorted(keys)))
pathline = [l for l in dump if l.startswith("PATH=")]
ok("verb PATH is rooted", bool(pathline) and
   pathline[0] == "PATH=%s/usr/fx-core/bin:%s/fx/store/bin:/bin:/usr/bin" % (root, root),
   repr(pathline))
ok("verb env carries FX_STORE (rooted store)",
   "FX_STORE=%s/fx/store" % root in dump, repr(dump))

# 13/14 — native file verbs, sandboxed under the root
d = call("fx_write", {"path": "/note.txt", "content": "hello fx\n"}, 20)
ok("fx_write", tool_text(d).startswith("exit=0\n"), tool_text(d))
ok("fx_write landed inside the root (sandboxed)",
   open(os.path.join(root, "note.txt")).read() == "hello fx\n"
   and not os.path.exists("/note.txt"))
d = call("fx_read", {"path": "/note.txt"}, 21)
ok("fx_read round-trips", tool_text(d) == "exit=0\nhello fx\n", repr(tool_text(d)))
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

print("SMOKE: %d checks, %d failed" % (checks["n"], checks["failed"]))
sys.exit(1 if checks["failed"] else 0)
DRIVER
