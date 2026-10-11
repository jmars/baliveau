#!/bin/sh
# tests/qemu-agent.sh — B1: the fx-harness RUNS INSIDE a qemu guest.
#
# WHAT IT PROVES.  Images built by fx-init's OWN toolchain (tests/mkinitramfs.sh,
# scripts/fetch-kernel.sh, the pinned kernel) boot under qemu with the fx-harness
# staged as a payload, and the harness's own DETERMINISTIC, GREPPABLE output
# comes back on the serial console with no model, no proxy and no network.  No
# fx-init file is edited: the payload arrives through mkinitramfs.sh -r ROOTDIR
# and the services are declared by this lane's own configs.
#
#   BOOT A (arm 2 + arm 3 — the healthy boot)
#     /usr/fx-agent/bin/fx-agent, the OFFLINE LOOP, in-guest: a canned SSE
#     stream staged at /usr/fx-agent/chardev.sse, FX_CHARDEV pointed at it,
#     FX_AGENT_DATA on the virtio disk.  Its assistant text is a UNIQUE
#     marker (the recorded fixture's "hello", substituted by stage-guest.sh),
#     so the console line cannot come from anywhere else in the image.
#     Plus fx-verbs-server (the MCP tool server) as a console service: the
#     driver writes ONE JSON-RPC `initialize` frame on the serial line and the
#     guest's own reply comes back.  Every service here exits 0 or stays alive,
#     so fx-init's own verdict for this boot MUST be boot-ok v<N>.
#
#   BOOT B (arm 1 — the exec gate — with its own in-boot arch control)
#     /usr/fx-agent/bin/fx-agent with NO argv prints
#     "agent_main: --agent <agent> is required" (agent_main.c:391 — before any
#     config load, transport or model) => the static musl binary EXECUTED in
#     the guest.  In the SAME boot, the i386 build of the same sources runs with
#     --agent and its signature line is "-p <prompt> is required": that line
#     MUST BE ABSENT, because the pinned kernel has
#     `# CONFIG_IA32_EMULATION is not set` and an EM_386 exec is impossible
#     there (execve -> ENOEXEC).  Same image, same config, same payload dir,
#     ONE variable changed (the binary's ELF class) — that asymmetry is what
#     makes the arm-1 line mean "ran", not "is present in the image".
#     tools/stage-guest.sh's host pre-checks prove both binaries DO print their
#     signature lines on a kernel WITH IA32 emulation.
#     Both services exit nonzero, so fx-init's verdict for this boot is
#     boot-FAILED BY CONSTRUCTION (fail-closed on any ST_FAILED service) — which
#     is asserted too, as evidence that the guest's exit status reached PID1.
#
#   BOOT C (the negative control — THE SAME STORE, the payload withheld)
#     an initramfs built from an EMPTY ROOTDIR, booted with BOOT B's config.
#     Every string the two positive boots assert must be ABSENT, and the
#     console must show the services failing to exec.  An assertion that cannot
#     fail is not a test: this is the run where it fails.
#
# THE GUEST ABI (the load-bearing measurement).  The harness's Makefile guest
# target is x86-linux-musl (i386) — right for the v86 lane, whose guest CPU is
# 32-bit, and WRONG for this one: the pinned kernel refuses EM_386 exec.  This
# harness therefore stages an x86_64-linux-musl build of the SAME sources
# (tools/stage-guest.sh builds it from the source list the Makefile itself
# declares) as the QEMU guest artifact, and keeps the repo's i386 artifact as
# the control.  No cross-repo change is needed for that; a Makefile target for
# the x86_64 guest build would be its tidier home (see the lane's report).
#
# Env: QEMU_BOOT_TIMEOUT (default 120)  QEMU_KEEP=1 keeps the scratch dir
#      QEMU_AGENT_SETTLE (default 12) seconds of quiet before each qemu kill,
#      so the guest's disk writeback (the belt) can reach the image
#      FX_INIT_REPO (default ../fx-init)  FX_SSE_FIXTURE  FX_KERNEL_CACHE
set -u

fail() { echo "qemu-agent: FAIL: $*" >&2; exit 1; }
skip() { echo "qemu-agent: SKIP ($*)"; exit 77; }

command -v qemu-system-x86_64 >/dev/null 2>&1 || skip "qemu-system-x86_64 not found"
command -v cpio >/dev/null 2>&1    || skip "cpio not found"
command -v gzip >/dev/null 2>&1    || skip "gzip not found"
command -v sha256sum >/dev/null 2>&1 || skip "sha256sum not found"
command -v timeout >/dev/null 2>&1 || skip "timeout(1) not found"
command -v qemu-img >/dev/null 2>&1 || skip "qemu-img not found (disk store)"
command -v python3 >/dev/null 2>&1 || skip "python3 not found (the pty driver)"
command -v zig >/dev/null 2>&1     || skip "zig not found (the guest toolchain)"
[ -e /dev/kvm ]                    || skip "/dev/kvm absent (qemu needs kvm)"
[ -w /dev/kvm ]                    || skip "/dev/kvm not writable"
MKE2FS=""
for _p in mke2fs /sbin/mke2fs /usr/sbin/mke2fs; do
    if command -v "$_p" >/dev/null 2>&1 || [ -x "$_p" ]; then MKE2FS="$_p"; break; fi
done
[ -n "$MKE2FS" ] || skip "mke2fs not found (e2fsprogs)"

cd "$(dirname "$0")/.." || fail "cannot cd to repo root"
REPO="$PWD"
INIT="${FX_INIT_REPO:-$(cd "$REPO/.." && pwd)/fx-init}"
BOOT_TIMEOUT="${QEMU_BOOT_TIMEOUT:-120}"
[ -d "$INIT" ] || skip "fx-init checkout not found at $INIT (set FX_INIT_REPO)"
PIN="$INIT/scripts/kernel-pin.txt"
[ -f "$PIN" ] || skip "scripts/kernel-pin.txt missing"

# ─── scratch (created before the kernel block: the fetch cache lives here) ─
WORK="$(mktemp -d "${TMPDIR:-/tmp}/qemuagent.XXXXXX")" || fail mktemp
if [ "${QEMU_KEEP:-0}" = "1" ]; then
    trap 'echo "qemu-agent: scratch kept at $WORK"' EXIT
else
    trap 'rm -rf "$WORK"' EXIT
fi
STORE="$WORK/store"
NEGROOT="$WORK/root-neg"       # the negative control's (empty) ROOTDIR
EVID="${QEMU_AGENT_EVIDENCE_DIR:-$REPO/build/guest-payload/evidence}"
mkdir -p "$EVID" || fail "cannot create the evidence dir $EVID"

# ─── pinned kernel (fx-init's own fetcher + pin; never the host's /boot) ───
KCACHE="${FX_KERNEL_CACHE:-$INIT/.kernel-cache}"
KERNEL="$KCACHE/kernel/vmlinuz"
KCONFIG="$KCACHE/kernel/config"
WANT_SHA=$(sed -n 's/^vmlinuz_sha256 //p' "$PIN")
[ -n "$WANT_SHA" ] || skip "kernel pin file malformed (needs 'vmlinuz_sha256 ...')"
if [ -r "$KERNEL" ] && [ "$(sha256sum "$KERNEL" | awk '{print $1}')" = "$WANT_SHA" ]; then
    echo "qemu-agent: pinned kernel verified in cache ($KERNEL)"
else
    KCACHE="$WORK/kernel-cache"
    FETCH_OUT=$(FX_KERNEL_CACHE="$KCACHE" sh "$INIT/scripts/fetch-kernel.sh" 2>&1)
    FETCH_RC=$?
    echo "$FETCH_OUT"
    [ "$FETCH_RC" = 0 ] || [ "$FETCH_RC" = 77 ] || fail "fetch-kernel failed (rc=$FETCH_RC)"
    [ "$FETCH_RC" = 0 ] || skip "pinned kernel artifact unavailable (offline) — no host-kernel fallback by design"
    KERNEL="$KCACHE/kernel/vmlinuz"; KCONFIG="$KCACHE/kernel/config"
    [ "$(sha256sum "$KERNEL" | awk '{print $1}')" = "$WANT_SHA" ] \
        || fail "kernel pin mismatch after fetch (want $WANT_SHA)"
fi

# ─── the payload (tools/stage-guest.sh owns build/guest-payload/) ─────────
echo "=== qemu-agent: staging the guest payload ==="
sh "$REPO/tools/stage-guest.sh" || fail "tools/stage-guest.sh failed"
PAYLOAD="$REPO/build/guest-payload"
PAYROOT="$PAYLOAD/root"
CFG_HEALTHY="$PAYLOAD/fx-agent-service-healthy.dhall"
CFG_GATE="$PAYLOAD/fx-agent-service-gate.dhall"
MARKER="$(cat "$PAYLOAD/marker.txt")"
SENTINEL="$(cat "$PAYLOAD/sentinel.txt")"
[ -n "$MARKER" ] || fail "no marker in $PAYLOAD/marker.txt"
[ -x "$PAYROOT/usr/fx-agent/bin/fx-agent" ] || fail "payload has no fx-agent"
for c in "$CFG_HEALTHY" "$CFG_GATE"; do [ -f "$c" ] || fail "payload has no $c"; done

# ─── the guest ABI gate: the pinned kernel's IA32 emulation setting ───────
# The arch control's premise, read from the pinned kernel's OWN config (shipped
# in the same tarball as vmlinuz).  A missing config is reported, never assumed.
IA32=""
if [ -r "$KCONFIG" ]; then
    if grep -q '^CONFIG_IA32_EMULATION=y' "$KCONFIG"; then IA32=yes; else IA32=no; fi
    echo "qemu-agent: pinned kernel IA32_EMULATION=$IA32 (from $KCONFIG)"
else
    echo "qemu-agent: WARNING: $KCONFIG absent — the i386 arch control cannot be interpreted" >&2
fi
[ "$IA32" = "yes" ] && { echo "qemu-agent: IA32 emulation IS on — the i386 control is not applicable"; }

# ─── freeze the package sources (two hash computations, one tree) ──────────
# Same concurrent-writer shield as fx-init/tests/qemu_ctrl.sh: activate_paths
# names the closure dirs by content hash and fx-activate recomputes those
# hashes; a source tree edited in between (other lanes DO edit the shared
# siblings) would name a different dir and the activation would report the
# package "not built".  Harness-only; no store semantics change.
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
echo "=== qemu-agent: freezing package sources ($INIT + its siblings) ==="
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

# ─── provisioning (fx-init's toolchain-free path; qemu_ctrl.sh's shape) ────
mkdir -p "$STORE" "$NEGROOT"
# fx-init's OWN guest binaries, built for the guest's ABI.  The repo's
# fx-init/zig/zig-out/bin currently holds i386-musl artifacts (MEASURED:
# `file` says EM_386), and the pinned kernel cannot exec an EM_386 ELF — the
# rdinit fails with `Failed to execute ... (error -8)` = ENOEXEC and the boot
# falls through to /bin/sh.  So this harness builds the guest set itself, for
# x86_64-linux-musl, into ITS OWN directory (build/guest-payload/, cached there
# between runs): nothing is written into the fx-init checkout, and the binary
# that boots is the one whose ELF class this script asserts below.
ZB="$REPO/build/guest-payload/init-x86_64-musl/bin"
if [ ! -x "$ZB/fx-init" ] || [ "${QEMU_AGENT_REBUILD_INIT:-0}" = 1 ]; then
    echo "=== qemu-agent: building fx-init's guest binaries (x86_64-linux-musl, ReleaseSafe) ==="
    ( cd "$INIT/zig" && zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe \
        -p "$REPO/build/guest-payload/init-x86_64-musl" \
        --cache-dir "$REPO/build/guest-payload/zig-init-cache" ) >"$WORK/fx-init-build.log" 2>&1
    # gate on the ARTIFACTS, never the step's aggregate exit (fx-init's own
    # harnesses tolerate the same: unrelated native-only steps can fail).
    for b in fx-init fx-activate fxctl activate_paths; do
        if [ ! -x "$ZB/$b" ]; then
            tail -30 "$WORK/fx-init-build.log" >&2
            fail "the fx-init guest build did not produce $ZB/$b"
        fi
        if command -v strip >/dev/null 2>&1; then strip "$ZB/$b" 2>/dev/null; fi
    done
fi
for b in fx-init fx-activate fxctl activate_paths; do
    [ -x "$ZB/$b" ] || skip "$ZB/$b absent — build it: cd $INIT/zig && zig build -Dtarget=x86_64-linux-musl -p $REPO/build/guest-payload/init-x86_64-musl"
    file -b "$ZB/$b" | grep -q 'x86-64' \
        || { file -b "$ZB/$b" >&2; fail "$ZB/$b is not x86-64 — the pinned kernel cannot exec it (see IA32_EMULATION above)"; }
done
echo "qemu-agent: guest binaries are x86_64 static: $(file -b "$ZB/fx-init" | cut -c1-60)"
echo "=== qemu-agent: provisioning the store (toolchain-free) ==="
export FX_SIBLINGS="${FX_SIBLINGS:-$SIBS}"
DL="$SIBS/datalog-dafsa/zig-out/lib"
[ -f "$DL/libdatalog.so" ] || skip "libdatalog.so missing at $DL (build the sibling)"
[ -x "$SIBS/dhake/dhake.com" ] || skip "prebuilt dhake.com missing"
cp "$SIBS/dhake/dhake.com" "$WORK/dhake.com"; chmod +x "$WORK/dhake.com"
"$WORK/dhake.com" --assimilate || fail "dhake --assimilate failed"
file "$WORK/dhake.com" 2>/dev/null | grep -q 'statically linked' \
    || skip "dhake.com did not assimilate to a static ELF on this host"
( cd "$INIT" && zig cc -target x86_64-linux-musl -std=gnu11 -O2 -static \
    -o "$WORK/fakesvc" tests/fixtures/fakesvc/fakesvc.c ) || fail "zig cc fakesvc failed"

PATHS=$(LD_LIBRARY_PATH="$DL" "$ZB/activate_paths" \
    --store "$STORE" --package-set "$PKGSET" \
    dhake fx-init fxctl fx-activate fake-service datalog-dafsa dhall-c fxstore) \
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
        *)                : > "$STORE/$pd/.provisioned-by-qemu-agent" ;;
    esac
done

# ─── two activations on ONE store: the healthy config, then the gate config.
# IMAGE-ORDER MATTERS: the initramfs carries a SNAPSHOT of the store, so the
# healthy image must be built while the store's CURRENT is v_A — before the
# gate config is activated.  v_A is activated first so it stays published
# BELOW v_B (the rollback harness's composition rule).
activate() { # activate CFG
    LD_LIBRARY_PATH="$DL" "$ZB/fx-activate" --store "$STORE" \
        --package-set "$PKGSET" --config "$1" 2>&1
}
image() { # image ROOTDIR LISTFILE OUT
    sh "$INIT/tests/mkinitramfs.sh" -s "$STORE" -r "$1" -k "$KERNEL" \
        -o "$3" -l "$2" || fail "mkinitramfs failed for ROOTDIR=$1"
}

echo "=== qemu-agent: activating the HEALTHY config (offline loop + tool server) ==="
OUT_A=$(activate "$CFG_HEALTHY") || fail "activate (healthy) failed: $OUT_A"
echo "$OUT_A"
V_A=$(echo "$OUT_A" | sed -n 's/.*as version \([0-9][0-9]*\).*/\1/p' | head -1)
[ -n "$V_A" ] || fail "cannot parse the healthy version from: $OUT_A"
echo "=== qemu-agent: building the healthy image (store CURRENT = v$V_A, payload via -r ROOTDIR) ==="
image "$PAYROOT" "$WORK/img-a.list" "$WORK/img-a.cpio.gz"
for want in usr/fx-agent/bin/fx-agent usr/fx-agent/bin/fx-agent.i386 \
            usr/fx-agent/bin/fx-verbs-server usr/fx-agent/chardev.sse \
            usr/fx-agent/cfg/config.dhall; do
    grep -qx "$want" "$WORK/img-a.list" || fail "the positive image does not carry $want"
done
echo "qemu-agent: the positive image carries the payload (5/5 payload paths checked)"
echo "--- positive image, payload paths ---"
grep 'usr/fx-agent' "$WORK/img-a.list"

echo "=== qemu-agent: activating the GATE config (exec gate + i386 control) ==="
OUT_B=$(activate "$CFG_GATE") || fail "activate (gate) failed: $OUT_B"
echo "$OUT_B"
V_B=$(echo "$OUT_B" | sed -n 's/.*as version \([0-9][0-9]*\).*/\1/p' | head -1)
[ -n "$V_B" ] || fail "cannot parse the gate version from: $OUT_B"
[ "$V_B" -gt "$V_A" ] || fail "gate version v$V_B not above healthy v$V_A (one store, two activations)"
FXD=$(ls -d "$STORE"/*-fx-init | head -1)
RDINIT="/fx/store/$(basename "$FXD")/fx-init"
image "$PAYROOT" "$WORK/img-b.list"   "$WORK/img-b.cpio.gz"     # gate store + payload
image "$NEGROOT" "$WORK/img-neg.list" "$WORK/img-neg.cpio.gz"   # gate store, NO payload
if grep -q 'fx-agent' "$WORK/img-neg.list"; then
    fail "the NEGATIVE image carries an fx-agent — the control would be void"
fi

# ─── the boot driver ──────────────────────────────────────────────────────
# qemu with -serial on a PTY (so the driver can WRITE the JSON-RPC frame to the
# guest's console — fx-init/tests/qemu_console.sh's driver shape); everything
# read is pumped into CONLOG, the driver waits for fx-init's verdict, sends the
# ARM 3 request, drains, and kills qemu.  ALL assertions live in the shell.
drive_boot() { # drive_boot IMG CONLOG TAG DISK
    _img=$1 _log=$2 _tag=$3
    : > "$_log"
    QEMU_AGENT_IMG="$_img" QEMU_AGENT_LOG="$_log" QEMU_AGENT_TAG="$_tag" \
    QEMU_AGENT_KERNEL="$KERNEL" QEMU_AGENT_RDINIT="$RDINIT" \
    QEMU_AGENT_DISK="$4" QEMU_AGENT_TIMEOUT="$BOOT_TIMEOUT" \
    QEMU_AGENT_SETTLE="${QEMU_AGENT_SETTLE:-12}" \
    python3 - <<'PYEOF'
import os, re, select, subprocess, sys, time

img = os.environ["QEMU_AGENT_IMG"]; conlog = os.environ["QEMU_AGENT_LOG"]
tag = os.environ["QEMU_AGENT_TAG"]; kernel = os.environ["QEMU_AGENT_KERNEL"]
rdinit = os.environ["QEMU_AGENT_RDINIT"]; disk = os.environ["QEMU_AGENT_DISK"]
timeout_s = int(os.environ["QEMU_AGENT_TIMEOUT"])
settle_s = int(os.environ["QEMU_AGENT_SETTLE"])

def bail(msg):
    sys.stderr.write("qemu-agent[%s]: %s\n" % (tag, msg))
    sys.exit(3)

qlog = conlog + ".qemu"
qout = open(qlog, "wb+")
qemu = subprocess.Popen(
    ["qemu-system-x86_64", "-machine", "q35", "-accel", "kvm", "-cpu", "host",
     "-m", "2048", "-smp", "1", "-display", "none", "-no-reboot",
     "-monitor", "none",
     "-kernel", kernel, "-initrd", img,
     "-append", "console=ttyS0,115200 rdinit=%s fx.store=/fx/store panic=-1 oops=panic" % rdinit,
     "-chardev", "pty,id=con", "-serial", "chardev:con",
     "-drive", "file=%s,format=raw,if=virtio" % disk],
    stdout=qout, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)

# qemu reports the pty path on its OWN stdout (MEASURED in qemu_console.sh: a
# stderr-only reader hangs for the whole boot)
pty_path, head = None, b""
deadline = time.time() + 20
while time.time() < deadline and pty_path is None:
    if qemu.poll() is not None:
        qout.seek(0)
        bail("qemu exited early rc=%s: %r" % (qemu.poll(), qout.read(400)))
    time.sleep(0.2)
    qout.seek(0)
    head = qout.read(65536)
    m = re.search(rb"redirected to (/dev/pts/\d+)", head)
    if m:
        pty_path = m.group(1).decode()
if pty_path is None:
    qemu.kill(); qemu.wait()
    bail("cannot find the pty path in qemu's output: %r" % head[:300])

ser = os.open(pty_path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
log = open(conlog, "wb")
buf = b""

def pump(secs):
    global buf
    end = time.time() + secs
    got = b""
    while time.time() < end:
        r, _, _ = select.select([ser], [], [], max(0.0, end - time.time()))
        if r:
            try:
                chunk = os.read(ser, 65536)
            except OSError:
                chunk = b""
            if chunk:
                got += chunk
    if got:
        buf += got
        log.write(got); log.flush()
    return got

verdict_re = re.compile(rb"fx-init: boot-(ok|FAILED) v(\d+)")
deadline = time.time() + timeout_s
verdict = None
while time.time() < deadline:
    pump(1)
    m = verdict_re.search(buf)
    if m:
        verdict = (m.group(1).decode(), m.group(2).decode()); break
    if qemu.poll() is not None:
        break

# ARM 3's request: one canonical MCP `initialize` frame on the serial line.
# Sent after the verdict (the services are up by then; the tty's canonical
# buffer holds it until the server reads it).
try:
    os.write(ser, b'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n')
except OSError as e:
    sys.stderr.write("qemu-agent[%s]: WARNING: cannot write the initialize frame: %s\n" % (tag, e))
end = time.time() + 15
while time.time() < end and b'"name":"fx-verbs"' not in buf:
    pump(1)

# let the guest's disk writes settle before the kill (the read-back belt)
time.sleep(settle_s)
pump(3)
qemu.kill(); qemu.wait()
os.close(ser); log.close()
sys.stderr.write("qemu-agent[%s]: verdict=%s, %d console bytes\n" % (tag, verdict, len(buf)))
sys.exit(0)
PYEOF
    return $?
}

# ─── BOOT A — arm 2 (the offline loop) + arm 3 (the tool server) ──────────
DISK_A="$WORK/disk-a.img"
qemu-img create -q "$DISK_A" 512M || fail "qemu-img create (A) failed"
"$MKE2FS" -q -t ext4 -J size=4 "$DISK_A" >/dev/null 2>&1 || fail "mke2fs (A) failed"
SHA_A0=$(sha256sum "$DISK_A" | awk '{print $1}')
echo "=== qemu-agent: BOOT A (healthy config v$V_A) — rdinit=$RDINIT ==="
drive_boot "$WORK/img-a.cpio.gz" "$WORK/console-a.log" A "$DISK_A" || fail "boot A driver failed"
cp "$WORK/console-a.log" "$EVID/boot-a-console.log"
echo "--- boot A: the console's verdict + execution lines ---"
grep -n 'fx-init: boot start store\|disk store mounted\|boot-ok\|boot-FAILED\|agent_main\|FX-GUEST-LOOP-OK\|fx-verbs' \
    "$WORK/console-a.log" | head -20

grep -q 'RAMDISK: \[mem 0x' "$WORK/console-a.log" || fail "boot A: no RAMDISK line — the initrd did not reach the kernel"
grep -qE 'Run /fx/store/.*-fx-init/fx-init as init process' "$WORK/console-a.log" \
    || { tail -30 "$WORK/console-a.log"; fail "boot A: no 'Run /fx/store/...-fx-init/fx-init as init process' line"; }
grep -q 'fx-init: boot-FAILED' "$WORK/console-a.log" \
    && { tail -30 "$WORK/console-a.log"; fail "boot A: boot-FAILED — a healthy service did not behave"; }
grep -q 'fx-init: disk store mounted (current v'"$V_A"')' "$WORK/console-a.log" \
    || { tail -30 "$WORK/console-a.log"; fail "boot A: no 'disk store mounted (current v$V_A)' line"; }
grep -q "fx-init: boot-ok v$V_A" "$WORK/console-a.log" \
    || { tail -40 "$WORK/console-a.log"; fail "boot A: no boot-ok v$V_A verdict"; }
SHA_A1=$(sha256sum "$DISK_A" | awk '{print $1}')
[ "$SHA_A0" != "$SHA_A1" ] || fail "boot A: disk-a.img unchanged — the guest never seeded the disk store"

grep -qF "$MARKER" "$WORK/console-a.log" \
    || { grep -n 'agent_main\|chardev' "$WORK/console-a.log" | head; fail "ARM 2: the loop's marker '$MARKER' is NOT on the console"; }
echo "qemu-agent: ARM 2 GREEN — the guest's offline loop printed '$MARKER' onto the serial console"
grep -q '"serverInfo":{"name":"fx-verbs"' "$WORK/console-a.log" \
    || { grep -n 'fx-verbs\|jsonrpc' "$WORK/console-a.log" | head; fail "ARM 3: no fx-verbs serverInfo reply on the console"; }
echo "qemu-agent: ARM 3 GREEN — fx-verbs-server answered a JSON-RPC initialize frame on the serial line"

# POST-PIVOT VISIBILITY (the whole reason -r ROOTDIR is equivalent to -b
# BINDIR here): /usr survives the pivot as a BIND of the initramfs tree, so
# the harness must still be runnable AFTER fx-init's pivot line — the marker
# and the tool-server reply must come LATER in the console than the pivot.
PIVOT_LN=$(grep -n 'fx-init: pivoted to tmpfs root' "$WORK/console-a.log" | head -1 | cut -d: -f1)
MARK_LN=$(grep -nF "$MARKER" "$WORK/console-a.log" | head -1 | cut -d: -f1)
VERB_LN=$(grep -nF '"serverInfo":{"name":"fx-verbs"' "$WORK/console-a.log" | head -1 | cut -d: -f1)
for _ln in "$PIVOT_LN" "$MARK_LN" "$VERB_LN"; do
    case "$_ln" in ''|*[!0-9]*) fail "boot A: cannot locate the pivot/marker/tool-server line numbers ($PIVOT_LN/$MARK_LN/$VERB_LN)";; esac
done
[ "$MARK_LN" -gt "$PIVOT_LN" ] \
    || fail "boot A: the loop's marker (line $MARK_LN) precedes the pivot (line $PIVOT_LN) — the payload was not exercised POST-pivot"
[ "$VERB_LN" -gt "$PIVOT_LN" ] \
    || fail "boot A: the tool server's reply (line $VERB_LN) precedes the pivot (line $PIVOT_LN)"
echo "qemu-agent: POST-PIVOT GREEN — pivot at console line $PIVOT_LN, the loop's marker at $MARK_LN, the tool server's reply at $VERB_LN"
grep -q 'agent_main' "$WORK/console-a.log" \
    && fail "boot A: an agent_main line appeared in the healthy boot (a stray fx-agent service?)"

# ─── BELT (reported, never gated): the loop's transcript ON THE DISK ──────
# FX_AGENT_DATA is on the virtio disk, so the guest's own messages.jsonl is
# in the image we can read from the host with debugfs.  Whether it is readable
# depends on the guest's writeback having reached the platter before the kill,
# so a missing read-back is NOT evidence the loop did not run (the console
# marker is the gate) — it is reported either way.
DBGFS=""
for _p in debugfs /sbin/debugfs /usr/sbin/debugfs; do
    if command -v "$_p" >/dev/null 2>&1 || [ -x "$_p" ]; then DBGFS="$_p"; break; fi
done
if [ -n "$DBGFS" ]; then
    echo "--- qemu-agent: disk read-back (belt) ---"
    # debugfs `ls -p` rows are <inode>/<mode>/<uid>/<gid>/<name>/ — the session
    # DIRECTORY's presence in the image is already evidence the guest created
    # FX_AGENT_DATA there (fx-agent's own mkdirs()); the transcript file only
    # reads back if its data reached the platter before the kill.
    SESS=$("$DBGFS" -R "ls -p /agent-data/sessions" "$DISK_A" 2>/dev/null)
    # NOTE the row shape: `.../0/0/<name>//` (debugfs -p appends TWO slashes),
    # so the name pattern must tolerate a trailing-run of '/' — requiring
    # exactly one reported a FALSE NEGATIVE for two runs (MEASURED: the
    # transcript was on the disk both times; the reader mis-parsed the row).
    SID=$(printf '%s\n' "$SESS" | sed -n 's|^/[0-9]*/[0-9]*/[0-9]*/[0-9]*/\([^/.][^/]*\)/*$|\1|p' | head -1)
    if [ -n "$SID" ]; then
        echo "  /agent-data/sessions/$SID/ exists IN THE DISK IMAGE (created in-guest)"
        "$DBGFS" -R "dump /agent-data/sessions/$SID/messages.jsonl $WORK/messages.jsonl" "$DISK_A" >/dev/null 2>&1
        if [ -s "$WORK/messages.jsonl" ]; then
            echo "  the guest's transcript, read back from the disk image ($(wc -c < "$WORK/messages.jsonl") bytes):"
            head -c 500 "$WORK/messages.jsonl" | sed 's/^/    /'; echo
            if grep -qF "$SENTINEL" "$WORK/messages.jsonl"; then
                echo "  ^ carries the sentinel prompt the service argv passed IN THE GUEST"
                cp "$WORK/messages.jsonl" "$EVID/boot-a-disk-transcript.jsonl"
            else
                echo "  ^ no sentinel in the read-back (partial flush) — belt only"
            fi
        else
            echo "  its messages.jsonl did not read back (data not flushed before the kill) — belt only, not a gate"
        fi
    else
        echo "  /agent-data/sessions not readable on the disk image — belt only, not a gate"
    fi
else
    echo "qemu-agent: no debugfs — skipping the disk read-back belt"
fi

# ─── BOOT B — arm 1 (the exec gate) with the in-boot i386 control ─────────
DISK_B="$WORK/disk-b.img"
qemu-img create -q "$DISK_B" 512M || fail "qemu-img create (B) failed"
"$MKE2FS" -q -t ext4 -J size=4 "$DISK_B" >/dev/null 2>&1 || fail "mke2fs (B) failed"
echo "=== qemu-agent: BOOT B (gate config v$V_B) — the exec gate + the i386 control ==="
drive_boot "$WORK/img-b.cpio.gz" "$WORK/console-b.log" B "$DISK_B" || fail "boot B driver failed"
cp "$WORK/console-b.log" "$EVID/boot-b-console.log"
echo "--- boot B: the verdict + every agent_main line ---"
grep -n 'fx-init: boot-ok\|fx-init: boot-FAILED\|agent_main\|exec failed' "$WORK/console-b.log" | head -20

grep -q 'agent_main: --agent <agent> is required' "$WORK/console-b.log" \
    || { tail -40 "$WORK/console-b.log"; fail "ARM 1: the harness's usage line is NOT on the guest console — the binary did not execute in-guest"; }
echo "qemu-agent: ARM 1 GREEN — 'agent_main: --agent <agent> is required' is on the GUEST's serial console"
# the nonzero exit must have reached PID1's state machine: fail-closed verdict
grep -q "fx-init: boot-FAILED v$V_B" "$WORK/console-b.log" \
    || { tail -40 "$WORK/console-b.log"; fail "boot B: expected fx-init's own boot-FAILED v$V_B (the harness's exit 2 must fail the boot)"; }
echo "qemu-agent: boot B verdict = boot-FAILED v$V_B — the harness's exit status propagated into fx-init's reaper"

if [ "$IA32" = "no" ]; then
    grep -q 'agent_main: -p <prompt> is required' "$WORK/console-b.log" \
        && { grep -n 'agent_main' "$WORK/console-b.log"; fail "ARCH CONTROL: the i386 binary's line appeared although CONFIG_IA32_EMULATION is off"; }
    echo "qemu-agent: ARCH CONTROL GREEN — the i386 build's '-p <prompt> is required' line is ABSENT in the same boot"
    NEXEC=$(grep -c 'fx-init: exec failed' "$WORK/console-b.log")
    echo "qemu-agent: the i386 service left $NEXEC 'fx-init: exec failed' line(s) — execvp's ENOEXEC path then fell through fx-init's /bin/sh retry (which has no target post-pivot) and _exit(127)'d"
else
    echo "qemu-agent: ARCH CONTROL not applicable (IA32_EMULATION=${IA32:-unknown})"
fi

# ─── BOOT C — the NEGATIVE CONTROL: the payload withheld ─────────────────
DISK_C="$WORK/disk-c.img"
qemu-img create -q "$DISK_C" 512M || fail "qemu-img create (C) failed"
"$MKE2FS" -q -t ext4 -J size=4 "$DISK_C" >/dev/null 2>&1 || fail "mke2fs (C) failed"
echo "=== qemu-agent: BOOT C (NEGATIVE CONTROL — the same config, no payload) ==="
drive_boot "$WORK/img-neg.cpio.gz" "$WORK/console-c.log" C "$DISK_C" || fail "boot C driver failed"
cp "$WORK/console-c.log" "$EVID/boot-c-neg-console.log"
echo "--- boot C: the verdict + execution lines ---"
grep -n 'fx-init: boot-ok\|fx-init: boot-FAILED\|agent_main\|exec failed\|FX-GUEST-LOOP-OK\|fx-verbs' \
    "$WORK/console-c.log" | head -20
NEG_BROKEN=0
for s in 'agent_main: --agent <agent> is required' 'agent_main: -p <prompt> is required' "$MARKER" '"serverInfo":{"name":"fx-verbs"'; do
    if grep -qF "$s" "$WORK/console-c.log"; then
        echo "qemu-agent: NEGATIVE CONTROL BROKEN — '$s' appears with no payload staged" >&2
        NEG_BROKEN=1
    fi
done
[ "$NEG_BROKEN" = 0 ] || { tail -30 "$WORK/console-c.log"; fail "the assertions pass on an image with no payload — they are not fireable"; }
grep -q 'fx-init: exec failed' "$WORK/console-c.log" \
    || echo "qemu-agent: NOTE: no 'fx-init: exec failed' line in the negative console — inspect the mechanism"
echo "qemu-agent: NEGATIVE CONTROL GREEN — all four asserted strings are ABSENT with the payload withheld"

echo
echo "qemu-agent: PASS"
echo "  boot A (v$V_A): fx-init boot-ok on the serial console; the offline loop printed '$MARKER' in-guest;"
echo "                  fx-verbs-server answered initialize over the serial line."
echo "  boot B (v$V_B): 'agent_main: --agent <agent> is required' from the guest; the i386 build's line absent;"
echo "                  fx-init's own verdict boot-FAILED (the harness's exit 2 reached PID1)."
echo "  boot C (v$V_B): the same four assertions FAIL without the payload (the control)."
exit 0
