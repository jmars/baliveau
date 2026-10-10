#!/bin/sh
# tests/qemu-luajit.sh — the x86_64 LuaJIT EXECUTES IN THE QEMU GUEST; the
# i386 one cannot.  THE ABI ASYMMETRY, IN ONE BOOT.
#
# WHAT THIS GATE IS FOR.  The repo's shipped LuaJIT artifact
# (build/luajit.musl) is i386: right for the v86 lane (32-bit guest CPU),
# WRONG for the qemu lane, whose pinned kernel has
# `# CONFIG_IA32_EMULATION is not set` — an EM_386 ELF cannot be exec'd there
# at all (binfmt_elf's elf_check_arch: execve -> ENOEXEC).  tools/
# build-luajit.sh therefore builds a SECOND artifact, build/luajit-x86_64.musl
# (same vendored tree, same capability bounds).  THIS gate proves the thing a
# host run cannot: that the x86_64 artifact RUNS IN THE GUEST, with the i386
# artifact as the negative control IN THE SAME BOOT.
#
# THE ONE BOOT (one disk, one image, three services):
#   heartbeat            fake-service, stays alive (the proven bracket shape)
#   luajit-run           /usr/fx-agent/bin/luajit (x86_64) runs the staged
#                        probe script with marker LUAJIT-X64-RAN: prints its
#                        line on the CONSOLE and writes a DURABLE marker file
#                        on the virtio disk (/fx/disk/LUAJIT-X64-RAN.txt).
#                        Exits 0.
#   luajit-i386          the SAME script via /usr/fx-agent/bin/luajit.i386
#                        with marker LUAJIT-I386-RAN — the NEGATIVE CONTROL.
#                        Same image, same config, same script; ONE variable
#                        differs (the binary's ELF class).  It must FAIL TO
#                        EXEC: no console line, no disk file, `fx-init: exec
#                        failed` on the console, and the boot verdict is
#                        boot-FAILED BY CONSTRUCTION (fx-init fail-closes on
#                        any failed service) — which is itself asserted, as
#                        evidence the exec failure reached PID1.
#
# THE DISK MARKER (the durable half of the proof): read back from the raw
# ext4 image with debugfs after the guest is killed (the settle+quiet+fsck
# belt the other gates use).  Its CONTENT carries more than presence: the
# JIT's two-sided trace counts (on>=1, off=0 — the JIT compiles traces IN
# THE GUEST) and the audit's ARM-2 hatch expectations (os.execute/io.popen
# must FAIL in the guest: system(3)/popen(3) need /bin/sh, which this guest
# does not ship), verified here for the first time IN a guest.
#
# NO STALE BYTES: the gate builds BOTH artifacts fresh, audits them, stages,
# and then CMPs three ways — built == staged == extracted-from-the-image — so
# the boot provably ran the bytes this gate built, not a cached neighbour.
# (A cached binary answering for a property of the system has bitten this
# repo three times; the cmp is the seat that makes it impossible here.)
#
# NOTHING READS A MOVING REF: no git invocation at all; the kernel is pinned
# by sha (fx-init/scripts/kernel-pin.txt), the package set is frozen and
# content-hashed, the LuaJIT tree by its PIN manifest.  The one input that
# is a working tree (the fx-init sibling) is frozen at gate time like every
# other gate.
#
# Env: QEMU_BOOT_TIMEOUT (default 120)  QEMU_KEEP=1  QEMU_AGENT_SETTLE (12)
#      FX_INIT_REPO  FX_KERNEL_CACHE
set -u

fail() { echo "qemu-luajit: FAIL: $*" >&2; exit 1; }
skip() { echo "qemu-luajit: SKIP ($*)"; exit 77; }

command -v qemu-system-x86_64 >/dev/null 2>&1 || skip "qemu-system-x86_64 not found"
command -v cpio >/dev/null 2>&1    || skip "cpio not found"
command -v gzip >/dev/null 2>&1    || skip "gzip not found"
command -v sha256sum >/dev/null 2>&1 || skip "sha256sum not found"
command -v timeout >/dev/null 2>&1 || skip "timeout(1) not found"
command -v qemu-img >/dev/null 2>&1 || skip "qemu-img not found (the disk)"
command -v python3 >/dev/null 2>&1 || skip "python3 not found (the image segment walker)"
command -v zig >/dev/null 2>&1     || skip "zig not found (the guest toolchain)"
command -v strip >/dev/null 2>&1   || skip "strip(1) not found"
command -v file >/dev/null 2>&1    || skip "file(1) not found"
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
[ -n "$DEBUGFS" ] || skip "debugfs not found (e2fsprogs; the disk read-back is load-bearing)"
E2FSCK=""
for _p in e2fsck /sbin/e2fsck /usr/sbin/e2fsck; do
    if command -v "$_p" >/dev/null 2>&1; then E2FSCK="$_p"; break; fi
done
[ -n "$E2FSCK" ] || skip "e2fsck not found (the post-boot belt)"

cd "$(dirname "$0")/.." || fail "cannot cd to repo root"
REPO="$PWD"
INIT="${FX_INIT_REPO:-$(cd "$REPO/.." && pwd)/fx-init}"
BOOT_TIMEOUT="${QEMU_BOOT_TIMEOUT:-120}"
SETTLE="${QEMU_AGENT_SETTLE:-12}"
[ -d "$INIT" ] || skip "fx-init checkout not found at $INIT (set FX_INIT_REPO)"
PIN="$INIT/scripts/kernel-pin.txt"
[ -f "$PIN" ] || skip "scripts/kernel-pin.txt missing"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qemulua.XXXXXX")" || fail mktemp
if [ "${QEMU_KEEP:-0}" = "1" ]; then
    trap 'echo "qemu-luajit: scratch kept at $WORK"' EXIT
else
    trap 'rm -rf "$WORK"' EXIT
fi
EVID="${QEMU_LUAJIT_EVIDENCE_DIR:-$REPO/tests/evidence/qemu-luajit}"
mkdir -p "$EVID" || fail "cannot create the evidence dir $EVID"

# ─── the pinned kernel + the arch premise, asserted not assumed ────────────
KCACHE="${FX_KERNEL_CACHE:-$INIT/.kernel-cache}"
KERNEL="$KCACHE/kernel/vmlinuz"
KCONFIG="$KCACHE/kernel/config"
WANT_SHA=$(sed -n 's/^vmlinuz_sha256 //p' "$PIN")
[ -n "$WANT_SHA" ] || skip "kernel pin file malformed (needs 'vmlinuz_sha256 ...')"
if [ -r "$KERNEL" ] && [ "$(sha256sum "$KERNEL" | awk '{print $1}')" = "$WANT_SHA" ]; then
    echo "qemu-luajit: pinned kernel verified in cache ($KERNEL)"
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
# THE NEGATIVE CONTROL'S DOMAIN: it is an i386-cannot-exec control ONLY on a
# kernel without IA32 emulation.  If the pin ever moves to a kernel WITH it,
# the control stops meaning what this gate says it means — fail, loudly.
if [ -r "$KCONFIG" ]; then
    grep -q '^CONFIG_IA32_EMULATION=y' "$KCONFIG" \
        && fail "the pinned kernel HAS IA32 emulation — the i386 negative control's premise is void, re-read this lane"
    echo "qemu-luajit: premise OK — pinned kernel has no IA32 emulation (an EM_386 exec is impossible in this guest)"
else
    fail "no kernel config at $KCONFIG — the IA32 premise cannot be asserted"
fi

# ─── ARM 0 (host): build BOTH artifacts fresh, audit them ─────────────────
echo "=== qemu-luajit: building both LuaJIT artifacts from clean ==="
sh "$REPO/tools/build-luajit.sh" all >"$WORK/luajit-build.log" 2>&1 \
    || { tail -30 "$WORK/luajit-build.log" >&2; fail "tools/build-luajit.sh all failed"; }
LJ64="$REPO/build/luajit-x86_64.musl"
LJ32="$REPO/build/luajit.musl"
[ -x "$LJ64" ] && [ -x "$LJ32" ] || fail "build-luajit reported success but an artifact is missing"
SHA64=$(sha256sum "$LJ64" | awk '{print $1}')
SHA32=$(sha256sum "$LJ32" | awk '{print $1}')
[ -n "$SHA64" ] && [ -n "$SHA32" ] || fail "cannot hash the artifacts"
echo "qemu-luajit: x86_64 artifact $LJ64 sha256 $SHA64"
echo "qemu-luajit: i386  artifact $LJ32 sha256 $SHA32"

echo "=== qemu-luajit: capability-bound audit, BOTH artifacts ==="
sh "$REPO/tests/luajit-audit.sh" "$LJ32" >"$WORK/audit-i386.log" 2>&1 \
    || { cat "$WORK/audit-i386.log" >&2; fail "the audit FAILED on the i386 artifact"; }
sh "$REPO/tests/luajit-audit.sh" "$LJ64" >"$WORK/audit-x64.log" 2>&1 \
    || { cat "$WORK/audit-x64.log" >&2; fail "the audit FAILED on the x86_64 artifact"; }
tail -1 "$WORK/audit-i386.log"; tail -1 "$WORK/audit-x64.log"

# ─── staging: payload via stage-guest.sh, then the three-way CMP ──────────
echo "=== qemu-luajit: staging the guest payload ==="
sh "$REPO/tools/stage-guest.sh" >"$WORK/stage.log" 2>&1 \
    || { tail -30 "$WORK/stage.log" >&2; fail "tools/stage-guest.sh failed"; }
PAYLOAD="$REPO/build/guest-payload"
PL_BIN="$PAYLOAD/root/usr/fx-agent/bin"
for f in luajit luajit.i386; do
    [ -x "$PL_BIN/$f" ] || { tail -20 "$WORK/stage.log" >&2; fail "payload has no $f"; }
done
# CMP 1/3 — staged == built (the gate's own bytes, not a cached neighbour):
cmp "$LJ64" "$PL_BIN/luajit"      || fail "staged luajit differs from the freshly built x86_64 artifact"
cmp "$LJ32" "$PL_BIN/luajit.i386" || fail "staged luajit.i386 differs from the freshly built i386 artifact"
echo "qemu-luajit: staged artifacts are byte-identical to the built ones (cmp)"

# ─── this gate's rootdir: the payload + the probe script ───────────────────
# A COPY of the staged payload root (never the staged tree itself — nothing
# this gate does may leak into another lane's image), plus the Lua probe.
ROOT="$WORK/root"
cp -a "$PAYLOAD/root" "$ROOT" || fail "cannot copy the payload root"
PROBE="$ROOT/usr/fx-agent/luajit-probe.lua"
cat > "$PROBE" <<'LUA'
-- qemu-luajit's in-guest probe.  argv[1] is the marker this invocation must
-- leave behind; the x86_64 service and the i386 control run the SAME file.
local marker = arg[1] or "no-marker"
-- JIT, two-sided (same shape as the build gate's): traces must start with
-- the JIT on, and none may start after jit.off().
local on_starts = 0
jit.attach(function(what) if what == "start" then on_starts = on_starts + 1 end end, "trace")
local s = 0
for i = 1, 300 do s = s + i * 2 end
jit.off()
local off_starts = 0
jit.attach(function(what) if what == "start" then off_starts = off_starts + 1 end end, "trace")
for i = 1, 300 do s = s + i * 2 end
-- audit ARM 2's hatch probes, run where they finally mean something: this
-- guest ships no /bin/sh, so system(3)/popen(3) must not succeed here.
local r = os.execute("true")
local sh_ok = (r == 0 or r == true)
local pf = io.popen("echo hi")
local popen_ok = (pf ~= nil)
-- the durable half of the proof: a file on the virtio disk
local f = assert(io.open("/fx/disk/" .. marker .. ".txt", "w"))
f:write(marker .. " arch=" .. jit.arch
        .. " traces=" .. on_starts .. "," .. off_starts
        .. " sh=" .. tostring(sh_ok)
        .. " popen=" .. tostring(popen_ok) .. "\n")
f:close()
print(marker .. " arch=" .. jit.arch .. " traces=" .. on_starts .. "," .. off_starts)
LUA
chmod 644 "$PROBE"

# ─── the service config: heartbeat + the x86_64 run + the i386 control ────
MARK64="LUAJIT-X64-RAN"
MARK32="LUAJIT-I386-RAN"
CFG="$WORK/luajit-service.dhall"
cat > "$CFG" <<DHALL
-- generated by tests/qemu-luajit.sh — do not edit in place
let Probe = < Tcp : Natural | Unix : Text | File : Text >
let Service = { name : Text, argv : List Text, pkg : Optional Text, on : Text,
                restart : Optional Text, backoffMs : Optional Natural,
                probe : Optional Probe,
                env : Optional (List { key : Text, value : Text }),
                console : Optional Text }
let User = { name : Text, uid : Natural, groups : List Text }
in  { hostname = "luabox"
    , packages = [ "dhake", "fx-init", "fxctl", "fx-activate", "fake-service" ]
    , users = [ { name = "root", uid = 0, groups = [] : List Text } ]
    , services =
        [ { name = "heartbeat", argv = [ "fakesvc", "ok" ], pkg = Some "fake-service",
            on = "all", restart = Some "always", backoffMs = Some 500,
            probe = None Probe,
            env = None (List { key : Text, value : Text }),
            console = None Text }
        , { name = "luajit-run", argv = [ "/usr/fx-agent/bin/luajit", "/usr/fx-agent/luajit-probe.lua", "$MARK64" ], pkg = None Text,
            on = "all", restart = Some "never", backoffMs = None Natural,
            probe = None Probe,
            env = None (List { key : Text, value : Text }),
            console = Some "console" }
        , { name = "luajit-i386", argv = [ "/usr/fx-agent/bin/luajit.i386", "/usr/fx-agent/luajit-probe.lua", "$MARK32" ], pkg = None Text,
            on = "all", restart = Some "never", backoffMs = None Natural,
            probe = None Probe,
            env = None (List { key : Text, value : Text }),
            console = Some "console" }
        ]
    , extraEtc = None (List { path : Text, content : Text })
    , bootGraceMs = Some 15000
    }
DHALL
[ -s "$CFG" ] || fail "cannot write the service config"
CCHK="$INIT/zig/zig-out/bin/config_check"
if [ -x "$CCHK" ]; then
    out=$("$CCHK" "$CFG" 2>&1) || { echo "$out" >&2; fail "config_check rejected the service config"; }
    n=$(printf '%s\n' "$out" | grep -c '^service\[[0-9]*\]\.name=')
    [ "$n" = 3 ] || fail "config_check saw $n services, want 3"
    echo "qemu-luajit: config_check OK — 3 services"
else
    echo "qemu-luajit: WARNING: $CCHK absent — the service config was not parser-checked" >&2
fi

# ─── freeze the package sources (concurrent-writer shield, qemu-agent's) ───
echo "=== qemu-luajit: freezing package sources ($INIT + its siblings) ==="
SIBS="$(cd "$INIT/.." && pwd)"
DL="$SIBS/datalog-dafsa/zig-out/lib"
[ -f "$DL/libdatalog.so" ] || skip "libdatalog.so missing at $DL (build the sibling)"
[ -x "$SIBS/dhake/dhake.com" ] || skip "prebuilt dhake.com missing"
freeze_src() { # freeze_src SRC DST
    mkdir -p "$2"
    ( cd "$1" && find . \
        -not -path "./.git/*"       -not -name ".git" \
        -not -path "./build-tmp/*"  -not -name "build-tmp" \
        -not -path "./zig-out/*"    -not -name "zig-out" \
        -not -path "./zig/zig-out/*" \
        -not -path "./zig/.zig-cache/*" -not -path "./zig/.zig-global/*" \
        -not -path "./node_modules/*" -not -name "node_modules" \
        -not -path "./elm-stuff/*"  -not -name "elm-stuff" \
        -not -path "./dist/*"     -not -name "dist" \
        -not -name "*.o" -not -name "*.a" -not -name "*.so" -not -name "*.com" \
        -not -name "dl-test-*" -not -name ".ape-*" \
        -print0 | cpio -pdm0 "$2" ) >/dev/null 2>&1 \
        || fail "cannot snapshot $1 -> $2"
}
FROZEN="$WORK/frozen"
mkdir -p "$FROZEN/siblings"
freeze_src "$SIBS/datalog-dafsa" "$FROZEN/siblings/datalog-dafsa"
freeze_src "$SIBS/dhall-c"       "$FROZEN/siblings/dhall-c"
freeze_src "$SIBS/fxstore"       "$FROZEN/siblings/fxstore"
freeze_src "$INIT"               "$FROZEN/fx-init"
sed -e "s|< Path = \"../../datalog-dafsa\" >|< Path = \"$FROZEN/siblings/datalog-dafsa\" >|" \
    -e "s|< Path = \"../../dhall-c\" >|< Path = \"$FROZEN/siblings/dhall-c\" >|" \
    -e "s|< Path = \"../../fxstore\" >|< Path = \"$FROZEN/siblings/fxstore\" >|" \
    -e "s|< Path = \"..\" >|< Path = \"$FROZEN/fx-init\" >|" \
    -e "s|< Path = \"../vendor/dhake\" >|< Path = \"$FROZEN/fx-init/vendor/dhake\" >|" \
    "$INIT/m3/package-set.dhall" > "$WORK/package-set.dhall" || fail "cannot rewrite the package set"
grep -q "$FROZEN" "$WORK/package-set.dhall" || fail "package-set rewrite produced no frozen paths"
PKGSET="$WORK/package-set.dhall"

# ─── provisioning (fx-init's toolchain-free path; qemu-agent's shape) ──────
export FX_SIBLINGS="${FX_SIBLINGS:-$SIBS}"
ZB="$REPO/build/guest-payload/init-x86_64-musl/bin"
if [ ! -x "$ZB/fx-init" ] || [ "${QEMU_AGENT_REBUILD_INIT:-0}" = 1 ]; then
    echo "=== qemu-luajit: building fx-init's guest binaries (x86_64-linux-musl, ReleaseSafe) ==="
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
        || fail "$ZB/$b is not x86-64 — the pinned kernel cannot exec it"
done
echo "=== qemu-luajit: provisioning the store (toolchain-free) ==="
STORE="$WORK/store"
mkdir -p "$STORE"
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
        *)                : > "$STORE/$pd/.provisioned-by-qemu-luajit" ;;
    esac
done

# ─── activate + build the image ────────────────────────────────────────────
echo "=== qemu-luajit: activating the luajit config ==="
OUT_V=$(LD_LIBRARY_PATH="$DL" "$ZB/fx-activate" --store "$STORE" \
    --package-set "$PKGSET" --config "$CFG" 2>&1) || fail "activate failed: $OUT_V"
echo "$OUT_V"
V=$(printf '%s\n' "$OUT_V" | sed -n 's/.*as version \([0-9][0-9]*\).*/\1/p' | head -1)
[ -n "$V" ] || fail "cannot parse the version from: $OUT_V"
FXD=$(ls -d "$STORE"/*-fx-init | head -1)
RDINIT="/fx/store/$(basename "$FXD")/fx-init"

IMG="$WORK/luajit.cpio.gz"
sh "$INIT/tests/mkinitramfs.sh" -s "$STORE" -r "$ROOT" -k "$KERNEL" \
    -o "$IMG" -l "$WORK/img.list" || fail "mkinitramfs failed"
for want in usr/fx-agent/bin/luajit usr/fx-agent/bin/luajit.i386 \
            usr/fx-agent/luajit-probe.lua; do
    grep -qx "$want" "$WORK/img.list" || fail "the image does not carry $want"
done
echo "qemu-luajit: the image carries both LuaJIT ABIs + the probe (v$V store)"

# CMP 2/3 and 3/3 — the IMAGE's bytes == the built bytes (extract, then cmp).
# The image is TWO CONCATENATED cpio archives (an early device-node segment,
# then the staged tree — mkinitramfs's early-cpio pattern), and cpio stops at
# the FIRST trailer, so extracting a payload file means skipping the dev
# segment first.  Its end offset is walked out of the bytes themselves (newc:
# 110-byte header, name+NUL, 4-byte pad; data size + pad), not parsed from
# mkinitramfs's chat — a changed dev set cannot silently misalign this.
XDIR="$WORK/img-extract"; mkdir -p "$XDIR"
gzip -dc "$IMG" > "$WORK/image.cpio" || fail "cannot gunzip the image"
DEVSEG=$(python3 - "$WORK/image.cpio" <<'PYEOF'
import sys
data = open(sys.argv[1], "rb").read()
off = 0
while True:
    if data[off:off+6] != b"070701":
        sys.stderr.write("bad newc magic at offset %d\n" % off); sys.exit(1)
    f = [int(data[off+6+8*i:off+14+8*i], 16) for i in range(13)]
    filesize, namesize = f[6], f[11]
    name = data[off+110:off+110+namesize-1]
    rec = 110 + namesize
    rec += (4 - (rec & 3)) & 3
    rec += filesize + ((4 - (filesize & 3)) & 3)
    off += rec
    if name == b"TRAILER!!!":
        print(off); sys.exit(0)
PYEOF
) || fail "cannot walk the image's dev segment"
tail -c +"$((DEVSEG + 1))" "$WORK/image.cpio" | ( cd "$XDIR" && cpio -id --quiet ) \
    || fail "cannot extract the main segment from the image"
[ -f "$XDIR/usr/fx-agent/bin/luajit" ] && [ -f "$XDIR/usr/fx-agent/bin/luajit.i386" ] \
    || fail "the extracted image has no LuaJIT binaries (devseg skip = $DEVSEG?)"
cmp "$LJ64" "$XDIR/usr/fx-agent/bin/luajit" \
    || fail "the image's luajit is NOT the freshly built x86_64 artifact (stale image bytes?)"
cmp "$LJ32" "$XDIR/usr/fx-agent/bin/luajit.i386" \
    || fail "the image's luajit.i386 is NOT the freshly built i386 artifact"
echo "qemu-luajit: the image's LuaJIT bytes are the freshly built ones (devseg $DEVSEG skipped, extract + cmp)"

# ─── the disk + the boot (qemu-agent-slot's driver shape) ──────────────────
DISK="$WORK/disk.img"
qemu-img create -q "$DISK" 512M || fail "qemu-img create failed"
"$MKE2FS" -q -t ext4 -J size=4 "$DISK" >/dev/null 2>&1 || fail "mke2fs failed"

qemu_pid=""
boot() { # boot IMG CONLOG
    _img=$1 _con=$2
    : > "$_con"
    qemu-system-x86_64 \
        -machine q35 -accel kvm -cpu host -m 2048 -smp 1 \
        -kernel "$KERNEL" -initrd "$_img" \
        -append "console=ttyS0,115200 rdinit=$RDINIT fx.store=/fx/store panic=-1 oops=panic" \
        -nographic -no-reboot -monitor none -serial file:"$_con" \
        -drive "file=$DISK,format=raw,if=virtio" \
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
wait_quiet() {
    _q=0 _prev=""
    while [ "$_q" -lt $((BOOT_TIMEOUT * 2)) ]; do
        _cur=$(sha256sum "$DISK" 2>/dev/null | awk '{print $1}')
        if [ -n "$_cur" ] && [ "$_cur" = "$_prev" ]; then return 0; fi
        _prev=$_cur; sleep 0.5; _q=$((_q + 1))
    done
    return 0
}
halt() {
    sleep "$SETTLE"
    wait_quiet
    kill "$qemu_pid" 2>/dev/null
    wait "$qemu_pid" 2>/dev/null
    qemu_pid=""
}

echo "=== qemu-luajit: the boot (x86_64 runs; i386 is the negative control) ==="
CON="$WORK/console.log"
boot "$IMG" "$CON"
cp "$CON" "$EVID/boot-console.log"
grep -n 'disk store mounted\|boot-ok\|boot-FAILED\|LUAJIT-\|exec failed\|luajit' "$CON" | head -12

# ── assertions on the console (each can fail) ──────────────────────────────
grep -q "fx-init: disk store mounted (current v$V)" "$CON" \
    || { tail -30 "$CON" >&2; halt; fail "no 'disk store mounted (current v$V)' line"; }
# POSITIVE: the x86_64 artifact EXECUTED (its console line, from its probe).
grep -qF "$MARK64 arch=x64 traces=" "$CON" \
    || { tail -40 "$CON" >&2; halt; fail "the x86_64 LuaJIT never ran (no '$MARK64' console line)"; }
# NEGATIVE CONTROL: the i386 artifact must NOT have executed — its marker
# line can only come from the probe running under luajit.i386.
if grep -qF "$MARK32" "$CON"; then
    halt; fail "the i386 LuaJIT RAN in the guest — the pinned kernel's no-IA32 premise is wrong"
fi
# The exec failure is ON the console and reached PID1 (the only possible
# exec failure in this boot is the i386 service: every other executable in
# the image is x86_64 and asserted so above or by stage-guest.sh).
grep -q 'fx-init: exec failed' "$CON" \
    || { tail -30 "$CON" >&2; halt; fail "no 'fx-init: exec failed' line — the i386 service's ENOEXEC never surfaced"; }
# The verdict: boot-FAILED BY CONSTRUCTION (fail-closed on the i386 service).
grep -q "fx-init: boot-FAILED v$V" "$CON" \
    || { tail -30 "$CON" >&2; halt; fail "want boot-FAILED v$V (the i386 control must fail the boot)"; }
echo "qemu-luajit: console OK — $MARK64 present, $MARK32 absent, exec failed + boot-FAILED v$V"
halt

# ── the durable half: the disk marker, read back from the raw image ───────
# e2fsck first (replay the journal after the kill); exit 0..3 is success-shaped.
"$E2FSCK" -fy "$DISK" >"$WORK/e2fsck.log" 2>&1
_rc=$?
[ "$_rc" -le 3 ] || { tail -8 "$WORK/e2fsck.log" >&2; fail "e2fsck -fy failed (rc=$_rc)"; }
# NOTE debugfs's exit code does NOT reflect a failed dump (MEASURED: rc=0,
# "File not found by ext2_lookup" on stderr, no output file created) — every
# read-back below asserts on the OUTPUT FILE and the stderr message, never
# on the exit code.
MARKFILE="$WORK/$MARK64.txt"
DUMP_MSG=$("$DEBUGFS" -R "dump /$MARK64.txt $MARKFILE" "$DISK" 2>&1 </dev/null)
[ -s "$MARKFILE" ] \
    || fail "no /$MARK64.txt off the disk — the durable marker is missing (debugfs: $DUMP_MSG)"
cp "$MARKFILE" "$EVID/$MARK64.txt"
echo "--- qemu-luajit: the durable marker, read back off the disk image ---"
cat "$MARKFILE"
# Content, not just presence: the marker line, x64 arch, TWO-SIDED JIT counts
# (>=1 trace with the JIT on, 0 after jit.off()), and the ARM-2 hatches held.
grep -Eq "^$MARK64 arch=x64 traces=[1-9][0-9]*,0 sh=false popen=false$" "$MARKFILE" \
    || fail "the disk marker's content is wrong (want '$MARK64 arch=x64 traces=N,0 sh=false popen=false'): $(cat "$MARKFILE")"
# And the control's marker file must NOT exist on the disk (asserted on the
# output file + the not-found message; see the NOTE above for why the exit
# code is worthless here).
CTRL_OUT="$WORK/$MARK32.txt"
rm -f "$CTRL_OUT"
CTRL_MSG=$("$DEBUGFS" -R "dump /$MARK32.txt $CTRL_OUT" "$DISK" 2>&1 </dev/null)
if [ -e "$CTRL_OUT" ]; then
    fail "the disk carries /$MARK32.txt — the i386 artifact RAN in the guest (premise void)"
fi
case "$CTRL_MSG" in
    *"File not found"*) ;;
    *) fail "the i386 marker's absence could not be established (debugfs: $CTRL_MSG)" ;;
esac
echo "qemu-luajit: disk OK — /$MARK64.txt present with the expected content; /$MARK32.txt absent"

# ─── evidence + exit ────────────────────────────────────────────────────────
{
    echo "gate       tests/qemu-luajit.sh"
    echo "kernel     $(sha256sum "$KERNEL" | awk '{print $1}')  (fx-init pin)"
    echo "x86_64-art $SHA64  build/luajit-x86_64.musl  (built, staged, in-image, EXECUTED in guest)"
    echo "i386-art   $SHA32  build/luajit.musl  (built, staged, in-image, REFUSED by guest: ENOEXEC)"
    echo "version    v$V"
    echo "marker     $(cat "$MARKFILE")"
} > "$EVID/facts.txt"
echo "=== qemu-luajit: PASS — x86_64 LuaJIT executed in the guest (marker on the disk); the i386 one could not ==="
exit 0
