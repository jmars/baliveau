#!/bin/sh
# tests/qemu-agent-b2.sh — B2: THE LOOP CLOSED, AGENT-DRIVEN, IN THE GUEST.
#
# WHAT IT PROVES.  The harness runs INSIDE a qemu guest (B1: tests/qemu-agent.sh
# proves that half), is driven by a RECORDED SSE stream (no model, no network),
# and through its OWN MCP TOOL SERVER (fx-verbs-server, spawned by the agent)
# it
#     1. INSPECTS the running system   (fx_ls /fx/disk/store, fx_read /etc/hostname)
#     2. REWRITES ITS OWN CONFIG       (fx_write /fx/disk/agent-config.dhall)
#     3. APPLIES IT                    (fx_activate /fx/disk/agent-config.dhall)
# and then the MACHINE IS RESTARTED against the SAME VIRTIO DISK and comes back
# up in the generation THE AGENT AUTHORED, with the verdict corroborating it.
#
# WHY THE CONFIG IS THE EDIT (not an Osier->Lua build): a config.dhall change
# needs no compiler, and the whole loop — inspect, change the config, restart,
# verdict, rollback — exists today.  Nothing here looks for an Osier backend.
#
# THE CONTROL CHANNEL IS ATTACHED.  B1's boot had none and fx-init said so
# ("no control channel ... and no virtio control port -- fxctl cannot connect
# in this guest").  Every boot here carries fx-init/tests/qemu_ctrl.sh's PROVEN
# invocation:
#   -chardev socket,id=fxctl0,path=$SOCK,server=on,wait=off
#   -device virtio-serial-pci -device virtserialport,chardev=fxctl0,name=fxctl0
# The HARNESS (host) uses it only as an ORACLE — it READS the guest's live state
# (`status`, `probe`, `q file`, `grep ...`) after the agent has acted.  It never
# writes the guest's store: every store mutation in this test is the AGENT's.
#
# "REBOOT" MEANS RESTART THE VM ON THE SAME DISK.  fx-init has NO reboot(2):
# do_shutdown() returns and PID 1 exits, i.e. a halt.  So each "restart" here is
# a fresh qemu against the same disk image, exactly as qemu_ctrl.sh does — and
# THE PERSISTENCE IS THE POINT: the store lives on the virtio disk
# (/fx/disk/store, fx-init's DISK_STORE) and VIBE_RUNTIME_DIR is on that disk
# (/fx/disk/agent-data), so the new generation and the agent's transcript both
# outlive the machine.  (The missing reboot(2) is reported as a finding, not
# patched here.)
#
# THE THREE ARMS
#   ARM 1 (disk1) — THE CHANGE SURVIVES
#     image 1's ramfs CURRENT is the AGENT BRACKET generation (heartbeat + the
#     fx-agent service carrying the arm-1 fixture).  boot A1: the agent runs its
#     four recorded tool calls; fx_activate commits a generation the HOST NEVER
#     CREATED (v_N > the image's CURRENT, parsed out of the agent's own tool
#     result) and its services start: "heartbeat from b2proof-<marker>" and
#     "fxstore: verify OK" land on the console.  boot A2 (SAME image, SAME disk,
#     no session): "disk store mounted (current v_N)" + "boot-ok v_N" +
#     the agent-authored service's heartbeat + fxstore verify OK => the machine
#     came back up in the new generation, and the verdict corroborates it.
#     Asserted too: the generation HASH before (host's activate output) and
#     after (the agent's tool result, read off the disk) differ; the config
#     read back off the disk is BYTE-IDENTICAL to the one the fixture carried.
#   ARM 2 (disk2) — THE CHANGE FAILS AND ROLLS BACK (the control for the
#     rollback machinery; without it the test cannot tell "the loop works" from
#     "nothing ever changed")
#     boot B0 (image P: an AGENT-FREE healthy generation) boots v_P ok — the
#     known-good generation the roll-forward needs.  boot B1 (image 2, the arm-2
#     fixture = a config whose only service exits 7): the agent activates the
#     crasher (v_BAD), the crasher fails in grace => "boot-FAILED v_BAD" and a
#     "<v_BAD> failed" line in the disk .bootlog.  boot B2: "stale failed for
#     v_BAD; rolling forward to v_P" + boot-ok v_ROLL (v_ROLL > v_BAD), and the
#     crasher's marker is ABSENT.
#   NEGATIVE CONTROL (disk3) — THE PAYLOAD WITHHELD
#     the SAME store as image 1, an EMPTY ROOTDIR: the agent service cannot
#     exec, NOTHING is activated, and the old generation persists across both
#     boots (current v_A1 in both).  Every string arm 1 asserts is absent here —
#     the assertions are fireable.
#
# THE AGENT'S INSPECTION VERBS.  The brief names fx_query / fx_status; both run
# `fxctl`, and fxctl has NO transport in this guest: CONFIG_NET is unset so
# socket(2) is ENOSYS and there is no control.sock, and the only chardev is the
# virtio control port whose SINGLE input queue PID1 itself reads (init.zig's
# g_shell_pid latch: "while the child owns the port, handle_virtio must not read
# it") — a second reader races PID1 for the request bytes.  So the agent
# inspects with the verbs that DO work in-guest: fx_ls + fx_read (native) and,
# for the activation, fx_activate — which now execs the RUNNING ROOT's
# /bin/fx-activate with the SAME argv fx-init's own activate handler uses
# (init.zig:2696).  See the lane's report: that is an in-repo (fx-harness)
# change, no other repo is touched.
#
# Env: QEMU_BOOT_TIMEOUT (default 120)  QEMU_KEEP=1  B2_MARKER  FX_INIT_REPO
#      FX_KERNEL_CACHE  B2_SKIP_BOOT=1 (stage + images only)
set -u

fail() { echo "qemu-agent-b2: FAIL: $*" >&2; exit 1; }
skip() { echo "qemu-agent-b2: SKIP ($*)"; exit 77; }

command -v qemu-system-x86_64 >/dev/null 2>&1 || skip "qemu-system-x86_64 not found"
command -v cpio >/dev/null 2>&1    || skip "cpio not found"
command -v gzip >/dev/null 2>&1    || skip "gzip not found"
command -v sha256sum >/dev/null 2>&1 || skip "sha256sum not found"
command -v timeout >/dev/null 2>&1 || skip "timeout(1) not found"
command -v qemu-img >/dev/null 2>&1 || skip "qemu-img not found (disk store)"
command -v python3 >/dev/null 2>&1 || skip "python3 not found (the fixture + channel driver)"
command -v zig >/dev/null 2>&1     || skip "zig not found (the guest toolchain)"
command -v strip >/dev/null 2>&1   || skip "strip(1) not found (guest artifacts must be stripped)"
[ -e /dev/kvm ]                    || skip "/dev/kvm absent (qemu needs kvm)"
[ -w /dev/kvm ]                    || skip "/dev/kvm not writable"
MKE2FS=""
for _p in mke2fs /sbin/mke2fs /usr/sbin/mke2fs; do
    if command -v "$_p" >/dev/null 2>&1 || [ -x "$_p" ]; then MKE2FS="$_p"; break; fi
done
[ -n "$MKE2FS" ] || skip "mke2fs not found (e2fsprogs)"
DEBUGFS=""
for _p in debugfs /sbin/debugfs /usr/sbin/debugfs; do
    if command -v "$_p" >/dev/null 2>&1 || [ -x "$_p" ]; then DEBUGFS="$_p"; break; fi
done
[ -n "$DEBUGFS" ] || skip "debugfs not found (e2fsprogs; the disk read-backs are load-bearing here)"
# the host's channel writer: nc -U (MEASURED in qemu_ctrl.sh: NOT -N — its
# half-close makes qemu tear the chardev down before the guest's response).
CTRL_TOOL=""
if nc -h 2>&1 | grep -q -- '-U.*UNIX domain socket'; then CTRL_TOOL=nc
elif command -v python3 >/dev/null 2>&1; then CTRL_TOOL=python3
else skip "no nc with -U and no python3 — cannot read the guest over the control channel"
fi

cd "$(dirname "$0")/.." || fail "cannot cd to repo root"
REPO="$PWD"
INIT="${FX_INIT_REPO:-$(cd "$REPO/.." && pwd)/fx-init}"
BOOT_TIMEOUT="${QEMU_BOOT_TIMEOUT:-120}"
SETTLE="${QEMU_AGENT_SETTLE:-12}"
[ -d "$INIT" ] || skip "fx-init checkout not found at $INIT (set FX_INIT_REPO)"
PIN="$INIT/scripts/kernel-pin.txt"
[ -f "$PIN" ] || skip "scripts/kernel-pin.txt missing"
MARKER="${B2_MARKER:-b2-agent-9f3c}"
SVC_PROOF="b2proof-$MARKER"
CONFIG_GUEST_PATH="/fx/disk/agent-config.dhall"
VIBE_DIR="/fx/disk/agent-data"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qemub2.XXXXXX")" || fail mktemp
if [ "${QEMU_KEEP:-0}" = "1" ]; then
    trap 'echo "qemu-agent-b2: scratch kept at $WORK"' EXIT
else
    trap 'rm -rf "$WORK"' EXIT
fi
EVID="${QEMU_AGENT_EVIDENCE_DIR:-$REPO/tests/evidence/qemu-agent-b2}"
mkdir -p "$EVID" || fail "cannot create the evidence dir $EVID"
SOCK="$WORK/chardev.sock"
STORE="$WORK/store"
NEGROOT="$WORK/root-neg"
mkdir -p "$STORE" "$NEGROOT"

# ─── pinned kernel (fx-init's own fetcher + pin; never the host's /boot) ───
KCACHE="${FX_KERNEL_CACHE:-$INIT/.kernel-cache}"
KERNEL="$KCACHE/kernel/vmlinuz"
WANT_SHA=$(sed -n 's/^vmlinuz_sha256 //p' "$PIN")
[ -n "$WANT_SHA" ] || skip "kernel pin file malformed"
if [ -r "$KERNEL" ] && [ "$(sha256sum "$KERNEL" | awk '{print $1}')" = "$WANT_SHA" ]; then
    echo "qemu-agent-b2: pinned kernel verified in cache"
else
    KCACHE="$WORK/kernel-cache"
    FETCH_OUT=$(FX_KERNEL_CACHE="$KCACHE" sh "$INIT/scripts/fetch-kernel.sh" 2>&1)
    FETCH_RC=$?
    echo "$FETCH_OUT"
    [ "$FETCH_RC" = 0 ] || [ "$FETCH_RC" = 77 ] || fail "fetch-kernel failed (rc=$FETCH_RC)"
    [ "$FETCH_RC" = 0 ] || skip "pinned kernel artifact unavailable (offline)"
    KERNEL="$KCACHE/kernel/vmlinuz"
    [ "$(sha256sum "$KERNEL" | awk '{print $1}')" = "$WANT_SHA" ] || fail "kernel pin mismatch after fetch"
fi

# ─── the payload (B1's tools/stage-guest.sh owns build/guest-payload/) ────
echo "=== qemu-agent-b2: staging B1's guest payload ==="
sh "$REPO/tools/stage-guest.sh" || fail "tools/stage-guest.sh failed"
PAYLOAD="$REPO/build/guest-payload"
PAYROOT="$PAYLOAD/root"
[ -x "$PAYROOT/usr/fx-agent/bin/fx-agent" ] || fail "payload has no fx-agent"
[ -x "$PAYROOT/usr/fx-agent/bin/fx-verbs-server" ] || fail "payload has no fx-verbs-server"

# ─── the guest ABI gate (B1's check, kept): the pinned kernel refuses EM_386 -
KCONFIG="$KCACHE/kernel/config"
if [ -r "$KCONFIG" ] && grep -q '^CONFIG_IA32_EMULATION=y' "$KCONFIG"; then
    fail "the pinned kernel HAS IA32 emulation — B1's arch control premise is void, re-read this lane"
fi

# ─── freeze the package sources (concurrent-writer shield) ────────────────
freeze_src() { # freeze_src SRC DST
    mkdir -p "$2"
    ( cd "$1" && find . \
        -not -path "./.git/*"       -not -name ".git" \
        -not -path "./build-tmp/*"  -not -name "build-tmp" \
        -not -path "./zig-out/*"    -not -name "zig-out" \
        -not -path "./zig/zig-out/*" \
        -not -path "./zig/.zig-cache/*" -not -path "./zig/.zig-global/*" \
        -not -path "./node_modules/*" -not -name "node_modules" \
        -not -path "./elm-stuff/*" -not -name "elm-stuff" \
        -not -path "./dist/*"     -not -name "dist" \
        -not -name "*.o" -not -name "*.a" -not -name "*.so" -not -name "*.com" \
        -not -name "dl-test-*" -not -name ".ape-*" \
        -print0 | cpio -pdm0 "$2" ) >/dev/null 2>&1 \
        || fail "cannot snapshot $1 -> $2"
}
echo "=== qemu-agent-b2: freezing package sources ($INIT + its siblings) ==="
SIBS="$(cd "$INIT/.." && pwd)"
mkdir -p "$WORK/frozen/siblings"
freeze_src "$SIBS/datalog-dafsa" "$WORK/frozen/siblings/datalog-dafsa"
freeze_src "$SIBS/dhall-c"       "$WORK/frozen/siblings/dhall-c"
freeze_src "$SIBS/fxstore"       "$WORK/frozen/siblings/fxstore"
freeze_src "$INIT"               "$WORK/frozen/fx-init"
sed -e "s|< Path = \"../../datalog-dafsa\" >|< Path = \"$WORK/frozen/siblings/datalog-dafsa\" >|" \
    -e "s|< Path = \"../../dhall-c\" >|< Path = \"$WORK/frozen/siblings/dhall-c\" >|" \
    -e "s|< Path = \"../../fxstore\" >|< Path = \"$WORK/frozen/siblings/fxstore\" >|" \
    -e "s|< Path = \"..\" >|< Path = \"$WORK/frozen/fx-init\" >|" \
    -e "s|< Path = \"../vendor/dhake\" >|< Path = \"$WORK/frozen/fx-init/vendor/dhake\" >|" \
    "$INIT/m3/package-set.dhall" > "$WORK/frozen/package-set.dhall"
grep -q "$WORK/frozen" "$WORK/frozen/package-set.dhall" || fail "package-set rewrite produced no frozen paths"
PKGSET="$WORK/frozen/package-set.dhall"

# ─── fx-init's guest binaries (x86_64-linux-musl; B1's rule: the pinned
#     kernel cannot exec EM_386, and the ELF CLASS IS ASSERTED) ───────────
ZB="$REPO/build/guest-payload/init-x86_64-musl/bin"
if [ ! -x "$ZB/fx-init" ] || [ "${QEMU_AGENT_REBUILD_INIT:-0}" = 1 ]; then
    echo "=== qemu-agent-b2: building fx-init's guest binaries (x86_64-linux-musl, ReleaseSafe) ==="
    ( cd "$INIT/zig" && zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe \
        -p "$REPO/build/guest-payload/init-x86_64-musl" \
        --cache-dir "$REPO/build/guest-payload/zig-init-cache" ) >"$WORK/fx-init-build.log" 2>&1
    for b in fx-init fx-activate fxctl activate_paths; do
        [ -x "$ZB/$b" ] || { tail -30 "$WORK/fx-init-build.log" >&2; fail "no $ZB/$b from the fx-init guest build"; }
        strip "$ZB/$b" 2>/dev/null
    done
fi
for b in fx-init fx-activate fxctl activate_paths; do
    [ -x "$ZB/$b" ] || skip "$ZB/$b absent"
    file -b "$ZB/$b" | grep -q 'x86-64' \
        || { file -b "$ZB/$b" >&2; fail "$ZB/$b is not x86-64 (the pinned kernel cannot exec it)"; }
done
echo "qemu-agent-b2: fx-init guest binaries are x86_64 static: $(file -b "$ZB/fx-init" | cut -c1-52)"

# ─── provisioning (toolchain-free path; qemu_ctrl.sh's shape) ─────────────
echo "=== qemu-agent-b2: provisioning the store (toolchain-free) ==="
export FX_SIBLINGS="${FX_SIBLINGS:-$SIBS}"
DL="$SIBS/datalog-dafsa/zig-out/lib"
[ -f "$DL/libdatalog.so" ] || skip "libdatalog.so missing at $DL"
[ -x "$SIBS/dhake/dhake.com" ] || skip "prebuilt dhake.com missing"
[ -x "$SIBS/fxstore/zig-out/bin/fxstore" ] || skip "the sibling fxstore binary is missing ($SIBS/fxstore/zig-out/bin/fxstore)"
cp "$SIBS/dhake/dhake.com" "$WORK/dhake.com"; chmod +x "$WORK/dhake.com"
"$WORK/dhake.com" --assimilate || fail "dhake --assimilate failed"
file "$WORK/dhake.com" 2>/dev/null | grep -q 'statically linked' || skip "dhake.com did not assimilate to a static ELF"
( cd "$INIT" && zig cc -target x86_64-linux-musl -std=gnu11 -O2 -static \
    -o "$WORK/fakesvc" tests/fixtures/fakesvc/fakesvc.c ) || fail "zig cc fakesvc failed"

PATHS=$(LD_LIBRARY_PATH="$DL" "$ZB/activate_paths" \
    --store "$STORE" --package-set "$PKGSET" \
    dhake fx-init fxctl fx-activate fake-service fxstore datalog-dafsa dhall-c) \
    || fail "activate_paths failed"
[ -n "$PATHS" ] || fail "activate_paths printed no closure"
echo "$PATHS" | while IFS= read -r pd; do
    mkdir -p "$STORE/$pd" || exit 1
    case "$pd" in
        *-fx-init)        cp "$ZB/fx-init"     "$STORE/$pd/fx-init";     chmod 755 "$STORE/$pd/fx-init" ;;
        *-fxctl)          cp "$ZB/fxctl"       "$STORE/$pd/fxctl";       chmod 755 "$STORE/$pd/fxctl" ;;
        *-fx-activate)    cp "$ZB/fx-activate" "$STORE/$pd/fx-activate"; chmod 755 "$STORE/$pd/fx-activate" ;;
        *-fake-service)   cp "$WORK/fakesvc"   "$STORE/$pd/fakesvc";     chmod 755 "$STORE/$pd/fakesvc" ;;
        *-dhake)          cp "$WORK/dhake.com" "$STORE/$pd/dhake.com";   chmod 755 "$STORE/$pd/dhake.com" ;;
        *)                : > "$STORE/$pd/.provisioned-by-qemu-agent-b2" ;;
    esac
done

# ─── the VERDICT tool: the sibling fxstore, STRIPPED, ELF CLASS ASSERTED ──
# `fxstore verify <rootfs>` is the reconciliation the verdict rests on ("N
# drift(s)" / "verify OK", exit 1 on drift).  It is provisioned into the
# store's own <hash>-fxstore dir, so mkinitramfs' ldd walk ships its closure
# (libdatalog.so) and the guest finds it at the DISK store path the generation
# materializes from.  The sibling's build output is NOT modified (a copy is
# stripped here).
FXSTORE_DIR=$(ls -d "$STORE"/*-fxstore 2>/dev/null | head -1)
[ -n "$FXSTORE_DIR" ] || fail "the closure has no *-fxstore dir"
cp "$SIBS/fxstore/zig-out/bin/fxstore" "$FXSTORE_DIR/fxstore" || fail "cannot stage fxstore"
chmod 755 "$FXSTORE_DIR/fxstore"
strip "$FXSTORE_DIR/fxstore" 2>/dev/null || fail "strip fxstore failed"
file -b "$FXSTORE_DIR/fxstore" | grep -q 'x86-64' \
    || { file -b "$FXSTORE_DIR/fxstore" >&2; fail "the staged fxstore is not x86-64"; }
file -b "$FXSTORE_DIR/fxstore" | grep -q 'stripped' \
    || skip "the staged fxstore is not stripped (strip(1) did not strip it)"
FXSTORE_IN_GUEST="/fx/disk/store/$(basename "$FXSTORE_DIR")/fxstore"
echo "qemu-agent-b2: fxstore staged at $FXSTORE_DIR/fxstore ($(file -b "$FXSTORE_DIR/fxstore" | cut -c1-40))"
echo "qemu-agent-b2: in-guest verdict binary: $FXSTORE_IN_GUEST"

# ─── the B2 payload rootdir: a COPY of B1's tree + the B2 additions ───────
# A copy, so tests/qemu-agent.sh's own payload tree (build/guest-payload/root)
# stays exactly what stage-guest.sh staged for B1.
ROOT_B2="$WORK/root-b2"
cp -a "$PAYROOT" "$ROOT_B2" || fail "cannot copy the payload rootdir"
mkdir -p "$ROOT_B2/usr/fx-agent/cfg-b2" || fail "cannot create the B2 config dir"
# the agent's RUNTIME config: ONE agent whose tool server is the harness's own
# fx-verbs-server (mcp_client spawns `command` with `args`, stdio, scrubbed env).
cat > "$ROOT_B2/usr/fx-agent/cfg-b2/config.dhall" <<DHALL
{ agents =
  [ { name = "fx"
    , agent_type = "agent"
    , mcp_servers =
      [ { command = "/usr/fx-agent/bin/fx-verbs-server"
        , args = [] : List Text
        }
      ] : List { command : Text, args : List Text }
    }
  ]
}
DHALL
[ -s "$ROOT_B2/usr/fx-agent/cfg-b2/config.dhall" ] || fail "cannot write the B2 runtime config"

# ─── the config the AGENT will author (the fixture carries it verbatim) ───
# Both are written as PLAIN FILES here, embedded into the SSE fixture below,
# and compared BYTE-FOR-BYTE against what the agent's fx_write left on the
# virtio disk.  The marker appears in the hostname AND in a service NAME that
# does not exist anywhere in the image, so the string on the post-restart
# console ("heartbeat from b2proof-<marker>") can only have come from the
# agent's own activation of the agent's own config.
svc_head() { # svc_head -> the shared Dhall type aliases + the heartbeat service
    cat <<'DHALL'
let Probe = < Tcp : Natural | Unix : Text | File : Text >
let Service = { name : Text, argv : List Text, pkg : Optional Text, on : Text,
                restart : Optional Text, backoffMs : Optional Natural,
                probe : Optional Probe,
                env : Optional (List { key : Text, value : Text }),
                console : Optional Text }
let User = { name : Text, uid : Natural, groups : List Text }
DHALL
}

# C1 — ARM 1's new generation: the agent's hostname, a marker service, and the
# fxstore verifier (whose EXIT STATUS is what fx-init's verdict judges).
{
    svc_head
    cat <<DHALL
in  { hostname = "$MARKER"
    , packages = [ "dhake", "fx-init", "fxctl", "fx-activate", "fake-service" ]
    , users = [ { name = "root", uid = 0, groups = [] : List Text } ]
    , services =
        [ { name = "heartbeat", argv = [ "fakesvc", "ok" ], pkg = Some "fake-service",
            on = "all", restart = Some "always", backoffMs = Some 500,
            probe = None Probe,
            env = None (List { key : Text, value : Text }),
            console = None Text }
        , { name = "$SVC_PROOF", argv = [ "fakesvc", "ok" ], pkg = Some "fake-service",
            on = "all", restart = Some "always", backoffMs = Some 500,
            probe = None Probe,
            env = None (List { key : Text, value : Text }),
            console = Some "console" }
        , { name = "b2verify", argv = [ "$FXSTORE_IN_GUEST", "verify", "/", "--store", "/fx/disk/store" ], pkg = None Text,
            on = "all", restart = Some "never", backoffMs = None Natural,
            probe = None Probe,
            env = None (List { key : Text, value : Text }),
            console = Some "console" }
        ]
    , extraEtc = None (List { path : Text, content : Text })
    , bootGraceMs = Some 15000
    }
DHALL
} > "$WORK/config1.dhall" || fail "cannot write config1"
# C2 — ARM 2: THE CHANGE THAT FAILS IN GRACE.  One service, exit 7: fx-init's
# verdict is fail-closed on any ST_FAILED service inside the grace window.
{
    svc_head
    cat <<DHALL
in  { hostname = "b2-crasher"
    , packages = [ "dhake", "fx-init", "fxctl", "fx-activate", "fake-service" ]
    , users = [ { name = "root", uid = 0, groups = [] : List Text } ]
    , services =
        [ { name = "b2crasher", argv = [ "fakesvc", "exit", "7" ], pkg = Some "fake-service",
            on = "all", restart = Some "never", backoffMs = None Natural,
            probe = None Probe,
            env = None (List { key : Text, value : Text }),
            console = Some "console" }
        ]
    , extraEtc = None (List { path : Text, content : Text })
    , bootGraceMs = Some 15000
    }
DHALL
} > "$WORK/config2.dhall" || fail "cannot write config2"
echo "--- config the agent will write, for arm 1 ($(wc -c < "$WORK/config1.dhall") bytes) ---"
sed 's/^/    /' "$WORK/config1.dhall"

# ─── the RECORDED SSE FIXTURES (the model, canned) ───────────────────────
# Four Responses-API function_call items in ONE response, dispatched by the
# loop IN ORDER, plus an assistant text part carrying a marker so the console
# proves the loop itself ran.  Multi-turn against a single recorded stream: the
# chardev transport SEEKs to 0 before every read (fx_transport.c), so every
# turn replays the SAME response — and the loop does NOT dispatch on its last
# turn (agent_loop.c: "if (t == max_turns - 1) break").  --max-turns 2 is
# therefore exactly ONE dispatch round of all four calls.  (B1's lane used the
# same recorded-stream offline arm; this reuses its mechanism.)
cat > "$WORK/mkb2.py" <<'PYEOF'
import json, sys

out, text, cfg_path, cfg_file, marker = sys.argv[1:6]
content = open(cfg_file).read()

def ev(name, obj):
    return "event: %s\ndata: %s\n\n" % (name, json.dumps(obj))

calls = [
    ("call_b2_ls",     "fx_ls",       {"path": "/fx/disk/store"}),
    ("call_b2_read",   "fx_read",     {"path": "/etc/hostname"}),
    ("call_b2_write",  "fx_write",    {"path": cfg_path, "content": content}),
    ("call_b2_activate", "fx_activate", {"config": cfg_path}),
]

s = []
s.append(ev("response.created", {"type": "response.created",
                                 "response": {"id": "b2-fixture", "status": "in_progress"}}))
s.append(ev("response.output_item.added",
            {"type": "response.output_item.added", "output_index": 0,
             "item": {"type": "message", "id": "m0", "status": "in_progress"}}))
s.append(ev("response.output_text.delta",
            {"type": "response.output_text.delta", "delta": text,
             "item_id": "m0", "output_index": 0}))
s.append(ev("response.output_text.done",
            {"type": "response.output_text.done", "text": text,
             "item_id": "m0", "output_index": 0}))
s.append(ev("response.output_item.done",
            {"type": "response.output_item.done", "output_index": 0,
             "item": {"type": "message", "id": "m0", "status": "completed"}}))
for i, (cid, name, args) in enumerate(calls):
    a = json.dumps(args)
    idx = i + 1
    s.append(ev("response.output_item.added",
                {"type": "response.output_item.added", "output_index": idx,
                 "item": {"type": "function_call", "id": "fc%d" % i,
                          "status": "in_progress", "call_id": cid,
                          "name": name, "arguments": ""}}))
    s.append(ev("response.function_call_arguments.delta",
                {"type": "response.function_call_arguments.delta",
                 "delta": a, "item_id": "fc%d" % i, "output_index": idx}))
    s.append(ev("response.function_call_arguments.done",
                {"type": "response.function_call_arguments.done",
                 "arguments": a, "item_id": "fc%d" % i, "output_index": idx}))
    s.append(ev("response.output_item.done",
                {"type": "response.output_item.done", "output_index": idx,
                 "item": {"type": "function_call", "id": "fc%d" % i,
                          "status": "completed", "call_id": cid,
                          "name": name, "arguments": a}}))
s.append(ev("response.completed",
            {"type": "response.completed",
             "response": {"id": "b2-fixture", "status": "completed"}}))
open(out, "w").write("".join(s))
print("wrote %s (%d bytes, %d function_call items)" % (out, len("".join(s)), len(calls)))
PYEOF
TEXT_MARKER="B2-AGENT-RAN-$MARKER"
python3 "$WORK/mkb2.py" "$ROOT_B2/usr/fx-agent/b2-arm1.sse" "$TEXT_MARKER" \
    "$CONFIG_GUEST_PATH" "$WORK/config1.dhall" "$MARKER" || fail "cannot build the arm-1 fixture"
python3 "$WORK/mkb2.py" "$ROOT_B2/usr/fx-agent/b2-arm2.sse" "$TEXT_MARKER" \
    "$CONFIG_GUEST_PATH" "$WORK/config2.dhall" "$MARKER" || fail "cannot build the arm-2 fixture"
grep -q "$SVC_PROOF" "$ROOT_B2/usr/fx-agent/b2-arm1.sse" || fail "the arm-1 fixture does not carry the marker service"
grep -q 'b2crasher'   "$ROOT_B2/usr/fx-agent/b2-arm2.sse" || fail "the arm-2 fixture does not carry the crasher"

# ─── the fx-init SERVICE configs (the generations the host activates) ─────
# The BRACKET generations carry the fx-agent service whose FX_CHARDEV is the
# recorded stream; the AGENT'S OWN generation (config1/2 above) never carries
# the agent, so a restart cannot re-run it.
agent_svc() { # agent_svc FIXTURE -> the fxagent service row (Dhall)
    cat <<DHALL
, { name = "fxagent-b2", argv = [ "/usr/fx-agent/bin/fx-agent", "-p", "inspect the system, rewrite the config, apply it", "--agent", "fx", "--max-turns", "2", "--output", "text" ], pkg = None Text,
            on = "all", restart = Some "never", backoffMs = None Natural,
            probe = None Probe,
            env = Some [ { key = "FX_CHARDEV", value = "$1" },
                         { key = "VIBE_RUNTIME_CONFIG_DIR", value = "/usr/fx-agent/cfg-b2" },
                         { key = "VIBE_RUNTIME_DIR", value = "$VIBE_DIR" },
                         { key = "HOME", value = "/tmp" }
                       ] : Optional (List { key : Text, value : Text }),
            console = Some "console" }
DHALL
}
gen_cfg() { # gen_cfg OUTFILE SERVICES_TAIL
    {
        svc_head
        cat <<DHALL
in  { hostname = "fixbox"
    , packages = [ "dhake", "fx-init", "fxctl", "fx-activate", "fake-service" ]
    , users = [ { name = "root", uid = 0, groups = [] : List Text } ]
    , services =
        [ { name = "heartbeat", argv = [ "fakesvc", "ok" ], pkg = Some "fake-service",
            on = "all", restart = Some "always", backoffMs = Some 500,
            probe = None Probe,
            env = None (List { key : Text, value : Text }),
            console = None Text }
        $2
        ]
    , extraEtc = None (List { path : Text, content : Text })
    , bootGraceMs = Some $3
    }
DHALL
    } > "$1" || fail "cannot write $1"
    [ -s "$1" ] || fail "$1 is empty"
}

gen_cfg "$WORK/svc-agent1.dhall" "$(agent_svc /usr/fx-agent/b2-arm1.sse)" 15000
gen_cfg "$WORK/svc-agent2.dhall" "$(agent_svc /usr/fx-agent/b2-arm2.sse)" 30000
gen_cfg "$WORK/svc-preboot.dhall" "" 12000          # arm 2's known-good, AGENT-FREE generation

# both configs must PARSE as fx-init reads them (fx-init's own config_check)
CCHK="$INIT/zig/zig-out/bin/config_check"
if [ -x "$CCHK" ]; then
    for c in "$WORK/config1.dhall" "$WORK/config2.dhall" "$WORK/svc-agent1.dhall" \
             "$WORK/svc-agent2.dhall" "$WORK/svc-preboot.dhall"; do
        out=$("$CCHK" "$c" 2>&1) || { echo "$out" >&2; fail "config_check rejected $c"; }
        echo "qemu-agent-b2: config_check OK — $(basename "$c"): $(printf '%s\n' "$out" | grep -c '^service\[[0-9]*\]\.name=') service(s)"
    done
else
    echo "qemu-agent-b2: WARNING: $CCHK absent — the configs were not parser-checked" >&2
fi

# ─── HOST PRE-CHECK: the fixture drives the tool server, ON THIS HOST ────
# The guest run's premises, measured BEFORE any boot: the recorded stream must
# make the loop dispatch EXACTLY these calls in this order, and the tool server
# must execute them through the SAME verb table (fx_write's content transfer
# included).  It runs against a STUB ROOT via the config's mcp_servers `env`
# overlay, so nothing on this host is touched — the guest run uses the default
# root "/" (which IS the guest's root).
if [ "${B2_SKIP_PRECHECK:-0}" != "1" ]; then
    if [ ! -x build/fx-agent ] || [ ! -x build/fx-verbs-server ]; then
        sh tools/build.sh >"$WORK/host-build.log" 2>&1 || { tail -20 "$WORK/host-build.log" >&2; fail "tools/build.sh failed"; }
    fi
    PC="$WORK/precheck"; rm -rf "$PC"
    mkdir -p "$PC/root/bin" "$PC/root/fx/disk/store" "$PC/root/etc" "$PC/data" "$PC/cfg"
    printf 'fixbox' > "$PC/root/etc/hostname"      # the guest's own pre-change hostname
    : > "$PC/root/fx/disk/store/.db"               # so fx_ls succeeds
    printf '0 ok 1\n' > "$PC/root/fx/disk/store/.bootlog"
    printf '#!/bin/sh\necho "stub fx-activate: $*"\necho "activated %s as version 8; buildfile /stub/Dhakefile.dhall"\nexit 0\n' \
        "1111111111111111111111111111111111111111111111111111111111111111" > "$PC/root/bin/fx-activate"
    printf '#!/bin/sh\necho "stub fxstore: $*"\necho "fxstore: verify OK"\nexit 0\n' > "$PC/root/bin/fxstore"
    chmod +x "$PC/root/bin/fx-activate" "$PC/root/bin/fxstore"
    cat > "$PC/cfg/config.dhall" <<DHALL
{ agents =
  [ { name = "fx"
    , agent_type = "agent"
    , mcp_servers =
      [ { command = "$REPO/build/fx-verbs-server"
        , args = [] : List Text
        , env = Some { FX_VERB_ROOT = "$PC/root" }
        }
      ]
    }
  ]
}
DHALL
    PCOUT=$(FX_CHARDEV="$ROOT_B2/usr/fx-agent/b2-arm1.sse" \
            VIBE_RUNTIME_CONFIG_DIR="$PC/cfg" VIBE_RUNTIME_DIR="$PC/data" HOME="$PC" \
            "$REPO/build/fx-agent" -p "inspect the system, rewrite the config, apply it" \
            --agent fx --max-turns 2 --output text 2>&1); PCRC=$?
    [ "$PCRC" = 0 ] || { echo "$PCOUT" >&2; fail "host pre-check: the loop exited rc=$PCRC"; }
    [ "$PCOUT" = "$TEXT_MARKER" ] || { echo "$PCOUT" >&2; fail "host pre-check: the loop printed '$PCOUT', want $TEXT_MARKER"; }
    PCLOG="$PC/data/sessions/$(ls "$PC/data/sessions" | head -1)/messages.jsonl"
    [ -s "$PCLOG" ] || fail "host pre-check: no transcript"
    NAMES=$(grep -o '"name":"fx_[a-z_]*"' "$PCLOG" | sed 's/.*"name":"//;s/"//' | head -4 | tr '\n' ' ')
    [ "$NAMES" = "fx_ls fx_read fx_write fx_activate " ] \
        || { cat "$PCLOG"; fail "host pre-check: dispatched tool names are '$NAMES', want fx_ls fx_read fx_write fx_activate"; }
    ORDER=$(grep -o '"id":"call_b2_[a-z]*"' "$PCLOG" | sed 's/.*"id":"//;s/"//' | head -4 | tr '\n' ' ')
    [ "$ORDER" = "call_b2_ls call_b2_read call_b2_write call_b2_activate " ] \
        || fail "host pre-check: tool-call order is '$ORDER', want ls, read, write, activate"
    FAILED=$(grep -c 'tool call failed' "$PCLOG" | tr -d ' ')
    [ "$FAILED" = "0" ] || { cat "$PCLOG"; fail "host pre-check: $FAILED tool call(s) failed to dispatch"; }
    NOK=$(grep -c '"content":"exit=0' "$PCLOG" | tr -d ' ')
    [ "$NOK" = "4" ] || { cat "$PCLOG"; fail "host pre-check: $NOK of the 4 tool results succeeded, want 4"; }
    grep -q 'wrote [0-9]* bytes to .*/fx/disk/agent-config.dhall' "$PCLOG" \
        || { cat "$PCLOG"; fail "host pre-check: no fx_write success line"; }
    grep -q 'exit=0.nfixbox' "$PCLOG" \
        || { cat "$PCLOG"; fail "host pre-check: fx_read did not return the pre-change hostname"; }
    grep -q 'activated .* as version 8' "$PCLOG" \
        || { cat "$PCLOG"; fail "host pre-check: no fx_activate result"; }
    cmp -s "$PC/root/fx/disk/agent-config.dhall" "$WORK/config1.dhall" \
        || fail "host pre-check: fx_write's content did not land byte-identical under the root"
    echo "qemu-agent-b2: HOST PRE-CHECK GREEN — the fixture dispatched fx_ls, fx_read, fx_write, fx_activate in order;"
    echo "                fx_write landed byte-identical under the stub root; fx_activate returned 'as version 8'."
fi

# ─── two activations on ONE store, then the images ───────────────────────
activate() { # activate CFG -> "activated <hash> as version N"
    LD_LIBRARY_PATH="$DL" "$ZB/fx-activate" --store "$STORE" \
        --package-set "$PKGSET" --config "$1" 2>&1
}
version_of() { sed -n 's/.*as version \([0-9][0-9]*\).*/\1/p' | head -1; }
hash_of()    { sed -n 's/^activated \([0-9a-f]*\) as version.*/\1/p' | head -1; }
image() { # image ROOTDIR LISTFILE OUT
    sh "$INIT/tests/mkinitramfs.sh" -s "$STORE" -r "$1" -k "$KERNEL" -o "$3" -l "$2" -p "$PKGSET" \
        || fail "mkinitramfs failed ($3)"
}

echo "=== qemu-agent-b2: activating the PRE-BOOT (agent-free) generation, then ARM 2's bracket ==="
OUT_P=$(activate "$WORK/svc-preboot.dhall") || fail "activate preboot failed: $OUT_P"
V_P=$(echo "$OUT_P" | version_of); [ -n "$V_P" ] || fail "cannot parse v_P from: $OUT_P"
echo "$OUT_P"
OUT_A2=$(activate "$WORK/svc-agent2.dhall") || fail "activate agent2 failed: $OUT_A2"
V_A2=$(echo "$OUT_A2" | version_of); [ -n "$V_A2" ] || fail "cannot parse v_A2 from: $OUT_A2"
[ "$V_A2" -gt "$V_P" ] || fail "v_A2 not above v_P"
echo "$OUT_A2"
echo "=== qemu-agent-b2: building image P (arm 2's pre-boot, CURRENT=v$V_P) ==="
image "$ROOT_B2" "$WORK/img-p.list" "$WORK/img-p.cpio.gz"
echo "=== qemu-agent-b2: building image 2 (arm 2's bracket, CURRENT=v$V_A2) ==="
image "$ROOT_B2" "$WORK/img-2.list" "$WORK/img-2.cpio.gz"
echo "=== qemu-agent-b2: activating ARM 1's bracket, then building image 1 + the negative image ==="
OUT_A1=$(activate "$WORK/svc-agent1.dhall") || fail "activate agent1 failed: $OUT_A1"
V_A1=$(echo "$OUT_A1" | version_of); [ -n "$V_A1" ] || fail "cannot parse v_A1 from: $OUT_A1"
H_A1=$(echo "$OUT_A1" | hash_of);    [ -n "$H_A1" ] || fail "cannot parse the arm-1 bracket hash"
[ "$V_A1" -gt "$V_A2" ] || fail "v_A1 not above v_A2"
echo "$OUT_A1"
image "$ROOT_B2" "$WORK/img-1.list"   "$WORK/img-1.cpio.gz"     # the agent bracket (arm 1) + payload
image "$NEGROOT" "$WORK/img-neg.list" "$WORK/img-neg.cpio.gz"   # SAME store, NO payload (the control)
for want in usr/fx-agent/bin/fx-agent usr/fx-agent/bin/fx-verbs-server \
            usr/fx-agent/cfg-b2/config.dhall usr/fx-agent/b2-arm1.sse usr/fx-agent/b2-arm2.sse; do
    grep -qx "$want" "$WORK/img-1.list" || fail "image 1 does not carry $want"
done
grep -q 'fx-agent' "$WORK/img-neg.list" && fail "the NEGATIVE image carries the payload — the control is void"
echo "qemu-agent-b2: image 1 carries the B2 payload (5/5 paths); the negative image carries none"

FXD=$(ls -d "$STORE"/*-fx-init | head -1)
RDINIT="/fx/store/$(basename "$FXD")/fx-init"

# ─── the host's channel session (the ORACLE; never a writer of the store) ─
ctrl_session() { # ctrl_session REQFILE TRANSCRIPT
    _req=$1 _out=$2
    case "$CTRL_TOOL" in
        nc) timeout 60 nc -w 8 -U "$SOCK" < "$_req" > "$_out" 2>&1 ;;
        python3) timeout 60 python3 -c '
import socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(sys.argv[1])
s.sendall(open(sys.argv[2], "rb").read())
s.settimeout(20); chunks = []; end = time.time() + 20
while time.time() < end:
    try: b = s.recv(4096)
    except socket.timeout: break
    if not b: break
    chunks.append(b)
sys.stdout.write(b"".join(chunks).decode("utf-8", "replace"))
' "$SOCK" "$_req" > "$_out" 2>&1 ;;
    esac
}

# ─── the boot driver (qemu_ctrl.sh's shape; -serial file so the console is
#     the artifact, + the fxctl0 chardev socket for the oracle session) ────
qemu_pid=""
boot() { # boot IMG CONLOG [with_session]
    _img=$1 _con=$2 _chan=${3:-0}
    : > "$_con"
    rm -f "$SOCK"
    qemu-system-x86_64 \
        -machine q35 -accel kvm -cpu host -m 2048 -smp 1 \
        -kernel "$KERNEL" -initrd "$_img" \
        -append "console=ttyS0,115200 rdinit=$RDINIT fx.store=/fx/store panic=-1 oops=panic" \
        -nographic -no-reboot -monitor none -serial file:"$_con" \
        -drive "file=$DISK,format=raw,if=virtio" \
        -chardev socket,id=fxctl0,path="$SOCK",server=on,wait=off \
        -device virtio-serial-pci -device virtserialport,chardev=fxctl0,name=fxctl0 \
        >"$WORK/qemu.$$.out" 2>&1 &
    qemu_pid=$!
    _i=0
    while [ "$_i" -lt $((BOOT_TIMEOUT * 2)) ]; do
        grep -q 'fx-init: boot-ok v\|fx-init: boot-FAILED v\|fx-init: no generation to boot' "$_con" && break
        kill -0 "$qemu_pid" 2>/dev/null || break
        sleep 0.5
        _i=$((_i + 1))
    done
    return 0
}
wait_quiet() { # disk quiescence before the abrupt kill (the store's writes)
    _q=0 _prev=""
    while [ "$_q" -lt $((BOOT_TIMEOUT * 2)) ]; do
        _cur=$(sha256sum "$DISK" 2>/dev/null | awk '{print $1}')
        if [ -n "$_cur" ] && [ "$_cur" = "$_prev" ]; then return 0; fi
        _prev=$_cur; sleep 0.5; _q=$((_q + 1))
    done
    return 0
}
halt() { # halt: settle the guest's disk writes, then stop the machine
    sleep "$SETTLE"
    wait_quiet
    kill "$qemu_pid" 2>/dev/null
    wait "$qemu_pid" 2>/dev/null
    qemu_pid=""
}
new_disk() { # new_disk FILE — journaled ext4 (qemu_ctrl.sh: a nojournal fs dies
             # on the inode bitmaps when the harness kills the VM)
    qemu-img create -q "$1" 512M || fail "qemu-img create ($1) failed"
    "$MKE2FS" -q -t ext4 -J size=4 "$1" >/dev/null 2>&1 || fail "mke2fs ($1) failed"
}
# read_file_from_disk PATH DEST — debugfs read-back off the raw image
read_from_disk() { "$DEBUGFS" -R "dump $1 $2" "$DISK" >/dev/null 2>&1; }

if [ "${B2_SKIP_BOOT:-0}" = "1" ]; then
    echo "qemu-agent-b2: B2_SKIP_BOOT=1 — staging complete (images in $WORK)"
    echo "qemu-agent-b2: v_P=$V_P v_A2=$V_A2 v_A1=$V_A1 (bracket hash $H_A1)"
    echo "qemu-agent-b2: PASS (stage-only)"
    exit 0
fi

# ═══ ARM 1 — the change survives the restart ═════════════════════════════
DISK="$WORK/disk1.img"; new_disk "$DISK"
echo "=== qemu-agent-b2: ARM 1 boot A1 (the agent: inspect -> write -> activate) ==="
boot "$WORK/img-1.cpio.gz" "$WORK/con-a1.log" 1
cp "$WORK/con-a1.log" "$EVID/boot-a1-console.log"
echo "--- A1: the verdict, the agent's actions, the new generation's services ---"
grep -n 'virtio control up\|boot-ok\|boot-FAILED\|B2-AGENT-RAN\|heartbeat from\|fxstore: verify\|pivoted to tmpfs' \
    "$WORK/con-a1.log" | head -25

grep -q 'fx-init: virtio control up (/dev/vport' "$WORK/con-a1.log" \
    || { tail -30 "$WORK/con-a1.log"; halt; fail "A1: no 'virtio control up' line — the control channel is not attached"; }
echo "qemu-agent-b2: CONTROL CHANNEL GREEN — fx-init brought the virtio control port up (A1)"
PIVOT_LN=$(grep -n 'fx-init: pivoted to tmpfs root' "$WORK/con-a1.log" | head -1 | cut -d: -f1)
RUN_LN=$(grep -nF "$TEXT_MARKER" "$WORK/con-a1.log" | head -1 | cut -d: -f1)
[ -n "$RUN_LN" ] || { tail -40 "$WORK/con-a1.log"; halt; fail "A1: the agent never ran (no '$TEXT_MARKER' on the console)"; }
[ -n "$PIVOT_LN" ] || fail "A1: no pivot line"
[ "$RUN_LN" -gt "$PIVOT_LN" ] || fail "A1: the agent's marker precedes the pivot — it did not run POST-pivot"
echo "qemu-agent-b2: AGENT RAN POST-PIVOT — pivot at line $PIVOT_LN, the agent's text at $RUN_LN"
# A1's verdict is the RUNNING (old) generation: the agent's fx_activate is a
# DIRECT exec of the root's activator, which publishes the generation in the
# store but does NOT go through PID1's channel handler — so the running system
# is NOT hot-applied and PID1 does not re-arm its boot decision.  The new
# generation takes effect at the RESTART (boot A2), which is exactly the
# "the machine comes back up in the new generation" shape this lane tests.
# Asserted as an ASYMMETRY, not hidden:
V_A1_RUN=$(sed -n 's/.*fx-init: boot-ok v\([0-9][0-9]*\).*/\1/p' "$WORK/con-a1.log" | head -1)
[ -n "$V_A1_RUN" ] || { tail -40 "$WORK/con-a1.log"; halt; fail "A1: no boot-ok verdict — the running generation did not settle"; }
[ "$V_A1_RUN" = "$V_A1" ] || fail "A1: the running verdict is v$V_A1_RUN, want the image's CURRENT v$V_A1"
grep -qF "heartbeat from $SVC_PROOF" "$WORK/con-a1.log" \
    && { halt; fail "A1: the agent-authored service IS running in the same boot — this lane expects the direct exec to be durable-but-not-hot-applied; re-derive the claim"; }
echo "qemu-agent-b2: NO-HOT-APPLY ASYMMETRY — the running generation is still v$V_A1 (boot-ok v$V_A1) and"
echo "                '$SVC_PROOF' is NOT running in boot A1: the agent's activation is DURABLE, applied at the restart"

# ── the ORACLE session (reads only; the guest is still running) ───────────
{ echo 'status'; echo 'probe'; echo 'q file'; echo "grep $SVC_PROOF"; echo 'grep b2verify'; } > "$WORK/req-a1.txt"
ctrl_session "$WORK/req-a1.txt" "$WORK/oracle-a1.txt"
cp "$WORK/oracle-a1.txt" "$EVID/boot-a1-oracle.txt"
echo "--- A1: the guest's LIVE state, read over the control channel by the harness ---"
sed -n '1,45p' "$WORK/oracle-a1.txt" | sed 's/^/    /'
grep -q "^  $V_A1\$" "$WORK/oracle-a1.txt" \
    || { halt; fail "A1 oracle: the live generation_current is not v$V_A1 (the running generation)"; }
echo "qemu-agent-b2: ORACLE GREEN — the guest's own live generation_current is v$V_A1 (the running generation)"
HOSTNAME_SIZE=$(grep '^/etc/hostname' "$WORK/oracle-a1.txt" | head -1 | awk -F'\t' '{print $2}')
[ "$HOSTNAME_SIZE" = "6" ] \
    || { echo "  /etc/hostname row: $(grep '^/etc/hostname' "$WORK/oracle-a1.txt" | head -1)"; halt; fail "A1 oracle: /etc/hostname size $HOSTNAME_SIZE, want 6 ('fixbox', the RUNNING generation's)"; }
grep -q 'b2verify' "$WORK/oracle-a1.txt" \
    && { halt; fail "A1 oracle: the agent's b2verify service is already running — this lane expects no hot-apply"; }
echo "qemu-agent-b2: ORACLE GREEN — /etc/hostname is 6 bytes ('fixbox') ON THE RUNNING ROOT; the agent's services are not running yet"
halt

# ── the disk read-backs (the agent's own record, off the virtio disk) ────
read_from_disk "/store/.bootlog" "$WORK/bootlog-a1.txt"
# the agent's own fx_write target: /fx/disk/agent-config.dhall == "/agent-config.dhall"
# inside the disk image (DISK_MOUNT=/fx/disk is the image's filesystem root)
read_from_disk "/agent-config.dhall" "$WORK/config-readback-a1.dhall"
"$DEBUGFS" -R "ls -p /agent-data/sessions" "$DISK" >"$WORK/sess-a1.txt" 2>/dev/null || true
SID=$(sed -n 's|^/[0-9]*/[0-9]*/[0-9]*/[0-9]*/\([^/.][^/]*\)/*$|\1|p' "$WORK/sess-a1.txt" | head -1)
[ -n "$SID" ] || { halt; fail "A1: no session dir under /agent-data/sessions on the disk (the agent's transcript is not persistent)"; }
read_from_disk "/agent-data/sessions/$SID/messages.jsonl" "$WORK/messages-a1.jsonl"
[ -s "$WORK/messages-a1.jsonl" ] || fail "A1: the agent's messages.jsonl did not read back (data not flushed)"
cp "$WORK/messages-a1.jsonl" "$EVID/boot-a1-disk-transcript.jsonl"
cp "$WORK/bootlog-a1.txt"    "$EVID/boot-a1-bootlog.txt"
echo "--- A1: the agent's OWN transcript, read back off the virtio disk ---"
sed 's/^/    /' "$WORK/messages-a1.jsonl" | cut -c1-220
grep -q 'fx_store\|fx_ls' "$WORK/messages-a1.jsonl" || fail "A1: the transcript carries no inspection tool call"
grep -q '"name":"fx_write"' "$WORK/messages-a1.jsonl" || fail "A1: the transcript carries no fx_write tool call"
grep -q '"name":"fx_activate"' "$WORK/messages-a1.jsonl" || fail "A1: the transcript carries no fx_activate tool call"
grep -q 'wrote [0-9]* bytes to /fx/disk/agent-config.dhall' "$WORK/messages-a1.jsonl" \
    || { halt; fail "A1: the fx_write result is not in the transcript"; }
H_NEW=$(sed -n 's/.*activated \([0-9a-f]\{40,\}\) as version \([0-9][0-9]*\).*/\1/p' "$WORK/messages-a1.jsonl" | head -1)
V_NEW=$(sed -n 's/.*activated \([0-9a-f]\{40,\}\) as version \([0-9][0-9]*\).*/\2/p' "$WORK/messages-a1.jsonl" | head -1)
[ -n "$H_NEW" ] || { halt; fail "A1: no 'activated <hash> as version N' in the agent's transcript (fx_activate produced no generation)"; }
grep -q 'src-free' "$WORK/messages-a1.jsonl" \
    || echo "qemu-agent-b2: NOTE: the in-guest activation did not report 'src-free' — inspect the closure path"
[ "$V_NEW" -gt "$V_A1" ] || fail "A1: the agent's generation v$V_NEW is not above the image's CURRENT v$V_A1"
echo "qemu-agent-b2: GENERATION BEFORE: v$V_A1 hash $H_A1 (the host's activation, the image's CURRENT)"
echo "qemu-agent-b2: GENERATION AFTER:  v$V_NEW hash $H_NEW (THE AGENT'S, activated in-guest)"
[ "$H_NEW" != "$H_A1" ] || fail "A1: the generation hash did NOT change — the agent's config is the image's config"
# the config the agent WROTE is byte-identical to the one the fixture carried
cmp -s "$WORK/config-readback-a1.dhall" "$WORK/config1.dhall" \
    || { halt; fail "A1: the config on the disk is NOT the config the agent's fixture carried"; }
cp "$WORK/config-readback-a1.dhall" "$EVID/boot-a1-disk-config.dhall"
echo "qemu-agent-b2: ARM 1 A1 GREEN — the config ON THE DISK is byte-identical to the fixture's ($(wc -c < "$WORK/config1.dhall") bytes)"

# ═══ ARM 1 boot A2 — THE RESTART: the new generation is what comes up ════
echo "=== qemu-agent-b2: ARM 1 boot A2 (SAME image, SAME disk — the restart) ==="
boot "$WORK/img-1.cpio.gz" "$WORK/con-a2.log" 0
cp "$WORK/con-a2.log" "$EVID/boot-a2-console.log"
echo "--- A2: the verdict, the persistence line, the agent-authored service, the verdict tool ---"
grep -n 'disk store mounted\|boot-ok\|boot-FAILED\|heartbeat from\|fxstore: verify' "$WORK/con-a2.log" | head -20
grep -q "fx-init: disk store mounted (current v$V_NEW)" "$WORK/con-a2.log" \
    || { tail -30 "$WORK/con-a2.log"; halt; fail "A2: the disk's CURRENT is not v$V_NEW — the agent's generation did not persist"; }
echo "qemu-agent-b2: PERSISTENCE GREEN — the restarted machine's disk store CURRENT is v$V_NEW (the agent's)"
grep -q "fx-init: boot-ok v$V_NEW" "$WORK/con-a2.log" \
    || { tail -30 "$WORK/con-a2.log"; halt; fail "A2: want boot-ok v$V_NEW"; }
grep -qF "heartbeat from $SVC_PROOF" "$WORK/con-a2.log" \
    || { grep -n 'heartbeat' "$WORK/con-a2.log" | head; halt; fail "A2: the agent-authored service is NOT running in the restarted machine"; }
echo "qemu-agent-b2: ARM 1 A2 GREEN — the restarted machine runs the AGENT'S service ($SVC_PROOF)"
VERIFY_OK_LN=$(grep -nF 'fxstore: verify OK' "$WORK/con-a2.log" | head -1 | cut -d: -f1)
[ -n "$VERIFY_OK_LN" ] \
    || { grep -n 'fxstore' "$WORK/con-a2.log" | head; halt; fail "A2: 'fxstore: verify OK' is NOT on the post-restart console — the verdict does not corroborate the new generation"; }
echo "qemu-agent-b2: VERDICT GREEN — post-restart fxstore verify says OK (line $VERIFY_OK_LN) and the boot verdict is boot-ok v$V_NEW (fx-init fails closed on any service exit != 0, so the OK line + boot-ok IS the exit-code channel)"
grep -nF 'fxstore: verify' "$WORK/con-a2.log" | sed 's/^/    /'
{ echo 'status'; echo 'probe'; echo 'q file'; echo 'grep b2verify'; } > "$WORK/req-a2.txt"
ctrl_session "$WORK/req-a2.txt" "$WORK/oracle-a2.txt"
cp "$WORK/oracle-a2.txt" "$EVID/boot-a2-oracle.txt"
echo "--- A2: the restarted guest's live state (control channel) ---"
sed -n '1,40p' "$WORK/oracle-a2.txt" | sed 's/^/    /'
grep -q "^  $V_NEW\$" "$WORK/oracle-a2.txt" || { halt; fail "A2 oracle: generation_current is not v$V_NEW"; }
HOSTNAME_SIZE2=$(grep '^/etc/hostname' "$WORK/oracle-a2.txt" | head -1 | awk -F'\t' '{print $2}')
[ "$HOSTNAME_SIZE2" = "${#MARKER}" ] \
    || { echo "  /etc/hostname row: $(grep '^/etc/hostname' "$WORK/oracle-a2.txt" | head -1)"; halt; fail "A2 oracle: /etc/hostname size $HOSTNAME_SIZE2, want ${#MARKER}"; }
grep -q 'b2verify.*exited (ok)' "$WORK/oracle-a2.txt" \
    || { grep -n 'b2verify' "$WORK/oracle-a2.txt" | head; halt; fail "A2 oracle: the b2verify service's exit status is not 'exited (ok)' in the guest's log DB"; }
echo "qemu-agent-b2: ORACLE GREEN (A2) — generation_current v$V_NEW, /etc/hostname ${#MARKER} bytes, 'b2verify ... exited (ok)' in the guest's own log DB"
halt
read_from_disk "/store/.bootlog" "$WORK/bootlog-a2.txt"
cp "$WORK/bootlog-a2.txt" "$EVID/boot-a2-bootlog.txt"
grep -q "^$V_NEW ok " "$WORK/bootlog-a2.txt" || { cat "$WORK/bootlog-a2.txt"; fail "A2: the disk .bootlog has no '$V_NEW ok' line"; }
echo "--- A2: the disk .bootlog (v status epoch) ---"; sed 's/^/    /' "$WORK/bootlog-a2.txt"

# ═══ ARM 2 — the change fails and rolls back ═════════════════════════════
DISK="$WORK/disk2.img"; new_disk "$DISK"
echo "=== qemu-agent-b2: ARM 2 boot B0 (image P: the agent-free known-good generation v$V_P) ==="
boot "$WORK/img-p.cpio.gz" "$WORK/con-b0.log" 0
cp "$WORK/con-b0.log" "$EVID/boot-b0-console.log"
grep -q "fx-init: boot-ok v$V_P" "$WORK/con-b0.log" \
    || { tail -30 "$WORK/con-b0.log"; halt; fail "B0: want boot-ok v$V_P (the known-good generation the roll-forward needs)"; }
grep -q 'B2-AGENT-RAN' "$WORK/con-b0.log" && fail "B0: the pre-boot generation is supposed to be AGENT-FREE"
echo "qemu-agent-b2: ARM 2 B0 GREEN — v$V_P booted ok, agent-free (the roll-forward target)"
halt

echo "=== qemu-agent-b2: ARM 2 boot B1 (the agent activates a config that FAILS in grace) ==="
boot "$WORK/img-2.cpio.gz" "$WORK/con-b1.log" 0
cp "$WORK/con-b1.log" "$EVID/boot-b1-console.log"
echo "--- B1: the running verdict + the agent ---"
grep -n 'disk store mounted\|boot-ok\|boot-FAILED\|B2-AGENT-RAN\|heartbeat from' "$WORK/con-b1.log" | head -15
grep -qF "$TEXT_MARKER" "$WORK/con-b1.log" \
    || { halt; fail "B1: the agent never ran (no '$TEXT_MARKER' on the console)"; }
grep -q "fx-init: boot-ok v$V_A2" "$WORK/con-b1.log" \
    || { tail -30 "$WORK/con-b1.log"; halt; fail "B1: want boot-ok v$V_A2 (the image's CURRENT; boot B0 left the disk at v$V_P, so the boot ADOPTS v$V_A2)"; }
echo "qemu-agent-b2: ARM 2 B1 GREEN — the ADOPT booted v$V_A2 and the agent ran in it"
halt
# the agent's own record of the failing config it activated
"$DEBUGFS" -R "ls -p /agent-data/sessions" "$DISK" >"$WORK/sess-b1.txt" 2>/dev/null || true
SID=$(sed -n 's|^/[0-9]*/[0-9]*/[0-9]*/[0-9]*/\([^/.][^/]*\)/*$|\1|p' "$WORK/sess-b1.txt" | head -1)
[ -n "$SID" ] || { fail "B1: no session dir on the disk"; }
read_from_disk "/agent-data/sessions/$SID/messages.jsonl" "$WORK/messages-b1.jsonl"
[ -s "$WORK/messages-b1.jsonl" ] || fail "B1: the agent's transcript did not read back"
cp "$WORK/messages-b1.jsonl" "$EVID/boot-b1-disk-transcript.jsonl"
read_from_disk "/agent-config.dhall" "$WORK/config-readback-b1.dhall"
cmp -s "$WORK/config-readback-b1.dhall" "$WORK/config2.dhall" \
    || { fail "B1: the config on the disk is NOT the crasher config the fixture carried"; }
V_BAD=$(sed -n 's/.*activated \([0-9a-f]\{40,\}\) as version \([0-9][0-9]*\).*/\2/p' "$WORK/messages-b1.jsonl" | head -1)
H_BAD=$(sed -n 's/.*activated \([0-9a-f]\{40,\}\) as version \([0-9][0-9]*\).*/\1/p' "$WORK/messages-b1.jsonl" | head -1)
[ -n "$V_BAD" ] || { cat "$WORK/messages-b1.jsonl" | cut -c1-200; fail "B1: no 'activated <hash> as version N' in the agent's transcript"; }
[ "$V_BAD" -gt "$V_A2" ] || fail "B1: the agent's crasher generation v$V_BAD is not above v$V_A2"
echo "qemu-agent-b2: ARM 2 B1 GREEN — the agent activated the CRASHER in-guest: v$V_BAD (hash ${H_BAD%????????*}),"
echo "                and the running generation stayed v$V_A2 (durable, not hot-applied — same asymmetry as ARM 1)"

echo "=== qemu-agent-b2: ARM 2 boot B2 (the RESTART — the crasher's generation boots and FAILS in grace) ==="
boot "$WORK/img-2.cpio.gz" "$WORK/con-b2.log" 0
cp "$WORK/con-b2.log" "$EVID/boot-b2-console.log"
echo "--- B2: the verdict + the crasher ---"
grep -n 'disk store mounted\|boot-ok\|boot-FAILED\|b2crasher\|fakesvc exit\|heartbeat from' "$WORK/con-b2.log" | head -15
grep -q "fx-init: disk store mounted (current v$V_BAD)" "$WORK/con-b2.log" \
    || { tail -30 "$WORK/con-b2.log"; halt; fail "B2: the disk's CURRENT is not v$V_BAD (the agent's crasher)"; }
grep -q 'fakesvc exit 7' "$WORK/con-b2.log" \
    || { grep -n 'crasher' "$WORK/con-b2.log" | head; halt; fail "B2: the crasher's own output is not on the console"; }
grep -q "fx-init: boot-FAILED v$V_BAD" "$WORK/con-b2.log" \
    || { tail -30 "$WORK/con-b2.log"; halt; fail "B2: want boot-FAILED v$V_BAD (the crasher must fail in grace)"; }
echo "qemu-agent-b2: ARM 2 B2 GREEN — the agent's crasher generation v$V_BAD booted and FAILED: boot-FAILED v$V_BAD"
halt
read_from_disk "/store/.bootlog" "$WORK/bootlog-b2.txt"
cp "$WORK/bootlog-b2.txt" "$EVID/boot-b2-bootlog.txt"
echo "--- B2: the disk .bootlog — the failure IS recorded ---"; sed 's/^/    /' "$WORK/bootlog-b2.txt"
grep -q "^$V_BAD failed " "$WORK/bootlog-b2.txt" \
    || { cat "$WORK/bootlog-b2.txt"; fail "B2: the disk .bootlog has no '$V_BAD failed' line"; }
ROLL_MSG="fx-init: stale failed for v$V_BAD; rolling forward to v$V_P"
echo "qemu-agent-b2: ARM 2 B2 GREEN — the disk .bootlog records '$V_BAD failed'"

echo "=== qemu-agent-b2: ARM 2 boot B3 (the SAME image and disk — roll forward to the known-good) ==="
boot "$WORK/img-2.cpio.gz" "$WORK/con-b3.log" 0
cp "$WORK/con-b3.log" "$EVID/boot-b3-console.log"
echo "--- B3: the roll-forward + the verdict ---"
grep -n 'rolling forward\|boot-ok\|boot-FAILED\|b2crasher\|heartbeat from' "$WORK/con-b3.log" | head -20
grep -qF "$ROLL_MSG" "$WORK/con-b3.log" \
    || { tail -30 "$WORK/con-b3.log"; halt; fail "B3: no '$ROLL_MSG' line"; }
V_ROLL=$(sed -n 's/.*fx-init: boot-ok v\([0-9][0-9]*\).*/\1/p' "$WORK/con-b3.log" | head -1)
[ -n "$V_ROLL" ] || { tail -30 "$WORK/con-b3.log"; halt; fail "B3: no boot-ok after the roll-forward"; }
[ "$V_ROLL" -gt "$V_BAD" ] || fail "B3: rolled v$V_ROLL not above v$V_BAD (not a roll FORWARD)"
grep -qF 'b2crasher' "$WORK/con-b3.log" && { halt; fail "B3: the crasher is STILL running after the roll-forward"; }
grep -qF 'heartbeat from heartbeat' "$WORK/con-b3.log" \
    || { grep -n 'heartbeat' "$WORK/con-b3.log" | head; halt; fail "B3: the restored generation's own service is not running"; }
echo "qemu-agent-b2: ARM 2 GREEN — the agent's failing config is recorded in the disk .bootlog, and the NEXT boot"
echo "                rolled forward to the known-good v$V_P: boot-ok v$V_ROLL, the crasher gone"
halt
read_from_disk "/store/.bootlog" "$WORK/bootlog-b3.txt"
cp "$WORK/bootlog-b3.txt" "$EVID/boot-b3-bootlog.txt"

# ═══ THE NEGATIVE CONTROL — the payload withheld, nothing changes ═══════
DISK="$WORK/disk3.img"; new_disk "$DISK"
echo "=== qemu-agent-b2: NEGATIVE CONTROL boot C1 (SAME store as image 1, NO payload) ==="
boot "$WORK/img-neg.cpio.gz" "$WORK/con-c1.log" 0
cp "$WORK/con-c1.log" "$EVID/boot-c1-neg-console.log"
echo "--- C1: the verdict + the exec failures ---"
grep -n 'boot-ok\|boot-FAILED\|exec failed\|B2-AGENT-RAN\|heartbeat from' "$WORK/con-c1.log" | head -12
grep -q 'fx-init: exec failed' "$WORK/con-c1.log" \
    || echo "qemu-agent-b2: NOTE: no 'fx-init: exec failed' line in the control console — inspect the mechanism"
grep -q "fx-init: boot-FAILED v$V_A1" "$WORK/con-c1.log" \
    || { tail -30 "$WORK/con-c1.log"; halt; fail "C1: want boot-FAILED v$V_A1 (the agent cannot exec without the payload)"; }
halt
echo "=== qemu-agent-b2: NEGATIVE CONTROL boot C2 (SAME image, SAME disk — nothing was activated) ==="
boot "$WORK/img-neg.cpio.gz" "$WORK/con-c2.log" 0
cp "$WORK/con-c2.log" "$EVID/boot-c2-neg-console.log"
grep -n 'disk store mounted\|boot-ok\|boot-FAILED\|B2-AGENT-RAN\|heartbeat from\|fxstore: verify' "$WORK/con-c2.log" | head -12
grep -q "fx-init: disk store mounted (current v$V_A1)" "$WORK/con-c2.log" \
    || { tail -30 "$WORK/con-c2.log"; halt; fail "C2: the generation changed without a payload — want the unchanged v$V_A1"; }
halt
NEG_BROKEN=0
for s in "$TEXT_MARKER" "heartbeat from $SVC_PROOF" 'fxstore: verify OK' 'agent-config.dhall'; do
    for f in "$WORK/con-c1.log" "$WORK/con-c2.log"; do
        if grep -qF "$s" "$f"; then
            echo "qemu-agent-b2: NEGATIVE CONTROL BROKEN — '$s' appears in $(basename "$f") with the payload withheld" >&2
            NEG_BROKEN=1
        fi
    done
done
[ "$NEG_BROKEN" = 0 ] || fail "the arm-1 assertions pass on an image with no payload — they are not fireable"
read_from_disk "/store/.bootlog" "$WORK/bootlog-c.txt"
cp "$WORK/bootlog-c.txt" "$EVID/boot-c-neg-bootlog.txt"
echo "--- C: the disk .bootlog (no new generation was ever created) ---"; sed 's/^/    /' "$WORK/bootlog-c.txt"
grep -q "^$V_A1 ok \|^$V_A1 failed " "$WORK/bootlog-c.txt" \
    || { cat "$WORK/bootlog-c.txt"; fail "C: the .bootlog carries no v$V_A1 line"; }
awk -v v="$V_A1" '$1 > v { found=1 } END { exit found ? 1 : 0 }' "$WORK/bootlog-c.txt" \
    || { cat "$WORK/bootlog-c.txt"; fail "C: a version ABOVE v$V_A1 exists — something was activated without the payload"; }
echo "qemu-agent-b2: NEGATIVE CONTROL GREEN — with the payload withheld NOTHING above v$V_A1 was ever created,"
echo "                the generation did not change, and all four asserted strings are ABSENT"

echo
echo "qemu-agent-b2: PASS"
echo "  ARM 1: the agent inspected, wrote $CONFIG_GUEST_PATH and ACTIVATED it in-guest through its own tool"
echo "         server -> v$V_NEW (hash ${H_NEW%????????*}, the host built v$V_A1 = ${H_A1%????????*});"
echo "         post-restart: current v$V_NEW, boot-ok v$V_NEW, 'heartbeat from $SVC_PROOF', fxstore verify OK."
echo "  ARM 2: the agent activated a crasher -> boot-FAILED v$V_BAD, '$V_BAD failed' in the disk .bootlog,"
echo "         the next boot rolled forward to the known-good v$V_P -> boot-ok v$V_ROLL, crasher gone."
echo "  CONTROL: no payload -> nothing above v$V_A1, all asserted strings absent."
exit 0
