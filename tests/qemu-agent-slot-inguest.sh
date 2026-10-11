#!/bin/sh
# tests/qemu-agent-slot-inguest.sh — THE BUILD INSIDE THE MACHINE.
#
# WHAT THIS GATE IS FOR.  tests/qemu-agent-slot.sh proves the slot plumbing
# with a HOST build step: the agent's source is read back off the disk,
# `fxstore build` runs on the HOST against a read-back copy of the store,
# and the result is injected into the image with debugfs -w.  That round
# trip is fine as a PROVISIONING path — but it cannot be the AGENT'S LOOP:
# every iteration would leave the machine and wait to come back.  This gate
# proves the loop the first self-modification task actually needs, and the
# unit of change it rests on:
#
#   THE IMAGE IS NOT THE UNIT OF CHANGE — THE STORE IS.  The agent is
#   already inside the machine; a new generation requires no image build,
#   no image patch, no injection.  ONE image and ONE disk serve the whole
#   gate; between boots the host does NOTHING to either (the initrd is
#   sha256-compared before each boot; the script contains no e2fsck, no
#   debugfs -w, and no second mkinitramfs between the loop boots — read
#   it).  The change is carried by the STORE on the disk, which the guest
#   itself wrote.
#
# THE LOOP, EVERY STEP IN THE GUEST (compiler still absent — the recipe is
# the same host-frozen STUB the slot gate uses):
#   boot 1  the agent (fixture) writes its Osier source + the slot config,
#           then calls the NEW PINNED VERB fx_build oslot: the payload's
#           x86_64-musl STATIC fxstore runs IN THE GUEST, loads the image's
#           frozen package set from /usr/fx, and builds the slot package
#           into the LIVE disk store (/fx/disk/store) — no read-back, no
#           host copy, no injection.  Two bound probes (an invented package
#           name, a flag-shaped argument) are REFUSED naming
#           FX_AGENT_BUILDABLE.  Then the agent activates the slot config
#           -> v_slot on the DISK store, and its record/store tamper probes
#           are refused.
#   boot 2  the SAME image (asserted byte-identical) and the SAME disk (the
#           host has not touched it): fx-init boots v_slot, the stub
#           service RUNS and marks the disk.
#   after   fx-osier-share over the guest-written store reads 0.000000
#           AS-OF the bracket version and NON-ZERO at v_slot, with the
#           oslot component attributed BY THE STORE (src_of, origin store),
#           and the store's own facts (store/srcstore/src_of) shown for the
#           slot off the disk the machine is running from.
#
# THE EXEC PROOFS, IN THE GUEST (a host run proves nothing here — that is
# the error this unit exists to correct):
#   fxstore  a CONSOLE service in the bracket runs the staged binary's
#            --help; its usage (with the `facts` capability line) lands on
#            the serial console, and the fx_build reply in the agent's own
#            transcript (on the disk) carries fxstore's build output.
#   stage3   a DEDICATED boot (its own store+disk, one generation) runs the
#            staged stage3 with no args as a console service: it prints its
#            usage line and exits 1, so the boot is FAILED BY CONSTRUCTION
#            (the SERVICE-GATE shape) — the console line proves the static
#            ELF exec'd under the pinned kernel, and the disk bootlog's
#            `failed` verdict proves the exit propagated into PID1's state
#            machine.  stage3 is never exec'd by the in-guest build itself:
#            fxstore DEMANDS it (X_OK, loud 127 without it) but the guest
#            has no bwrap, so the recipe takes fxstore's sanctioned LOUD
#            NON-HERMETIC fallback — which this gate requires VISIBLE in
#            the fx_build evidence, not silenced.
#
# WHAT THE HOST-BUILT GATE STILL PROVES (both gates stay green, by design):
#   qemu-agent-slot.sh proves the CROSS-MACHINE claim this gate cannot —
#   that a hash computed by a HOST build is adopted by the GUEST's
#   activation (built outside, activated inside), plus the e2fsck/debugfs
#   injection path itself (the provisioning shape a deployment without an
#   in-guest builder still needs).  This gate proves the IN-MACHINE claim:
#   written, built, activated and run without the bytes ever leaving.
#
# NO CONTROL CHANNEL: every assertion is the console or a read-only debugfs
# read-back off the virtio disk.
#
# Env: QEMU_BOOT_TIMEOUT (default 120)  QEMU_KEEP=1  FX_INIT_REPO
#      FX_KERNEL_CACHE  FXSTORE_BIN (host binary, read-only facts only)
#      INGUEST_SKIP_BOOT=1 (stage + images only)
set -u

fail() { echo "qemu-agent-slot-inguest: FAIL: $*" >&2; exit 1; }
skip() { echo "qemu-agent-slot-inguest: SKIP ($*)"; exit 77; }

command -v qemu-system-x86_64 >/dev/null 2>&1 || skip "qemu-system-x86_64 not found"
command -v cpio >/dev/null 2>&1    || skip "cpio not found"
command -v gzip >/dev/null 2>&1    || skip "gzip not found"
command -v sha256sum >/dev/null 2>&1 || skip "sha256sum not found"
command -v timeout >/dev/null 2>&1 || skip "timeout(1) not found"
command -v qemu-img >/dev/null 2>&1 || skip "qemu-img not found (disk store)"
command -v python3 >/dev/null 2>&1 || skip "python3 not found (the fixture)"
command -v zig >/dev/null 2>&1     || skip "zig not found (the guest toolchain)"
command -v strip >/dev/null 2>&1   || skip "strip(1) not found"
command -v file >/dev/null 2>&1    || skip "file(1) not found"
command -v readelf >/dev/null 2>&1 || skip "readelf not found (static assert)"
E2FSCK=""
for _p in e2fsck /sbin/e2fsck /usr/sbin/e2fsck; do
    if command -v "$_p" >/dev/null 2>&1; then E2FSCK="$_p"; break; fi
done
[ -n "${E2FSCK:-}" ] || skip "e2fsck not found (the initial disk prep only)"
MKE2FS=""
for _p in mke2fs /sbin/mke2fs /usr/sbin/mke2fs; do
    if command -v "$_p" >/dev/null 2>&1 || [ -x "$_p" ]; then MKE2FS="$_p"; break; fi
done
[ -n "$MKE2FS" ] || skip "mke2fs not found (e2fsprogs)"
DEBUGFS=""
for _p in debugfs /sbin/debugfs /usr/sbin/debugfs; do
    if command -v "$_p" >/dev/null 2>&1; then DEBUGFS="$_p"; break; fi
done
[ -n "$DEBUGFS" ] || skip "debugfs not found (e2fsprogs; the disk read-backs are load-bearing)"
[ -e /dev/kvm ]                    || skip "/dev/kvm absent (qemu needs kvm)"
[ -w /dev/kvm ]                    || skip "/dev/kvm not writable"

cd "$(dirname "$0")/.." || fail "cannot cd to repo root"
REPO="$PWD"
INIT="${FX_INIT_REPO:-$(cd "$REPO/.." && pwd)/fx-init}"
BOOT_TIMEOUT="${QEMU_BOOT_TIMEOUT:-120}"
SETTLE="${QEMU_AGENT_SETTLE:-12}"
[ -d "$INIT" ] || skip "fx-init checkout not found at $INIT (set FX_INIT_REPO)"
PIN="$INIT/scripts/kernel-pin.txt"
[ -f "$PIN" ] || skip "scripts/kernel-pin.txt missing"
SLOTSET="$INIT/m3/package-set-slot.dhall"
[ -f "$SLOTSET" ] || skip "m3/package-set-slot.dhall missing at $SLOTSET (the slot package set)"
MARKER="${SLOT_MARKER:-slot-agent-5f31}"
AGENT_DATA="/fx/disk/agent-data"
AGENT_CONFIG="/fx/disk/agent-config.dhall"
SLOT_SRC_DIR="/fx/disk/agent-src/oslot"       # the in-guest slot src.path
SLOT_SRC_FILE="$SLOT_SRC_DIR/Mcp.elm"         # THE one writable source path

# the HOST fxstore: used ONLY for the read-only `facts` evidence at the end
# (never for building — that is the point of this gate).  The BUILDER is the
# payload's static musl artifact, staged by tools/stage-guest.sh and asserted
# below.
FXSTORE="${FXSTORE_BIN:-$REPO/../fxstore/zig-out/bin/fxstore}"
[ -x "$FXSTORE" ] || skip "fxstore binary missing at $FXSTORE (build the sibling)"
"$FXSTORE" --help 2>&1 | grep -q 'fxstore facts' || skip "fxstore at $FXSTORE predates 'facts' (rebuild the sibling)"
OSIER="${OSIER_BIN:-$REPO/build/fx-osier-share}"
[ -x "$OSIER" ] || fail "no oracle binary at $OSIER (make test-osier-share builds it)"

# the pinned kernel cannot exec i386 (MEASURED, tests/qemu-agent-observe.sh)
# and CAN exec #! scripts — both asserted.  NO SECCOMP in this kernel is
# asserted too: it is WHY the stage3 probe runs the bare usage shape (arg
# parsing, before any sandboxing) rather than a sandboxed child, and why the
# in-guest build's bwrap-absent fallback (which never execs stage3) is the
# expected path there.
KCONFIG_PRE="${FX_KERNEL_CACHE:-$INIT/.kernel-cache}/kernel/config"
kconfig_asserts() {
    grep -q '^CONFIG_BINFMT_SCRIPT=y' "$1" \
        || fail "the pinned kernel has no BINFMT_SCRIPT — the stub runner (a #! script) could never exec; re-read this lane"
    grep -q '^CONFIG_IA32_EMULATION=y' "$1" \
        && fail "the pinned kernel HAS IA32 emulation — the guest-ABI premise is void, re-read this lane"
    grep -q '^CONFIG_SECCOMP=y' "$1" \
        && echo "qemu-agent-slot-inguest: NOTE — kernel has SECCOMP (unexpected; the stage3 probe is still the bare-usage shape)"
}
[ -r "$KCONFIG_PRE" ] && kconfig_asserts "$KCONFIG_PRE"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qemuinguest.XXXXXX")" || fail mktemp
if [ "${QEMU_KEEP:-0}" = "1" ]; then
    trap 'echo "qemu-agent-slot-inguest: scratch kept at $WORK"' EXIT
else
    trap 'rm -rf "$WORK"' EXIT
fi
EVID="${QEMU_INGUEST_EVIDENCE_DIR:-$REPO/tests/evidence/qemu-agent-slot-inguest}"
mkdir -p "$EVID" || fail "cannot create the evidence dir $EVID"

# ─── the pinned kernel (fx-init's own fetcher + pin) ─────────────────────
KCACHE="${FX_KERNEL_CACHE:-$INIT/.kernel-cache}"
KERNEL="$KCACHE/kernel/vmlinuz"
WANT_SHA=$(sed -n 's/^vmlinuz_sha256 //p' "$PIN")
[ -n "$WANT_SHA" ] || skip "kernel pin file malformed"
if [ -r "$KERNEL" ] && [ "$(sha256sum "$KERNEL" | awk '{print $1}')" = "$WANT_SHA" ]; then
    echo "qemu-agent-slot-inguest: pinned kernel verified in cache"
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
KCONFIG="$KCACHE/kernel/config"
[ -r "$KCONFIG" ] && kconfig_asserts "$KCONFIG"

# ─── the guest payload + fx-init's guest binaries ────────────────────────
echo "=== qemu-agent-slot-inguest: staging the guest payload ==="
sh "$REPO/tools/stage-guest.sh" || fail "tools/stage-guest.sh failed"
PAYLOAD="$REPO/build/guest-payload"
PAYROOT="$PAYLOAD/root"
PL_BIN="$PAYROOT/usr/fx-agent/bin"
for b in fx-agent fx-verbs-server; do
    [ -x "$PL_BIN/$b" ] || fail "payload has no $b"
done
# THE IN-GUEST BUILD PAIR + the recipe interpreter, all staged by the payload:
#   fxstore  the builder (static x86_64-musl; 0 NEEDED is the guest standard)
#   stage3   the sandbox binary fxstore demands before any Shell recipe
#   sh       FXSTORE_SH's target (the pivoted root has no /bin/sh) — a
#            busybox applet link resolving inside the assembled image
[ -x "$PL_BIN/fxstore" ] || fail "payload has no fxstore (the in-guest builder)"
[ -x "$PL_BIN/stage3" ] || fail "payload has no stage3 (fxstore refuses every Shell recipe without it)"
[ -L "$PL_BIN/sh" ] || [ -x "$PL_BIN/sh" ] || fail "payload has no sh applet (FXSTORE_SH's target)"
assert_guest_elf() { # assert_guest_elf FILE ARCHDESC
    _f=$1 _d=$2
    [ -f "$_f" ] || fail "$_f missing"
    _t=$(file -b "$_f" 2>/dev/null)
    case "$_t" in *"statically linked"*) ;; *) fail "$_f is not static: $_t" ;; esac
    case "$_t" in *"stripped"*) ;; *) fail "$_f is not stripped: $_t" ;; esac
    case "$_t" in *"$_d"*) ;; *) fail "$_f is not $_d: $_t" ;; esac
}
assert_guest_elf "$PL_BIN/fxstore" "x86-64"
# 0 NEEDED, asserted (the repo's guest-artifact standard; a dynamic fxstore
# cannot run in a musl guest at all — the reason this unit exists):
readelf -d "$PL_BIN/fxstore" >/dev/null 2>&1
if readelf -d "$PL_BIN/fxstore" 2>&1 | grep -q NEEDED; then
    fail "$PL_BIN/fxstore carries NEEDED entries — a dynamic artifact cannot exec in the musl guest"
fi
# the staged fx-verbs-server must CARRY the verb (a payload frozen before
# fx_build would fail the loop with an unattributable unknown-tool error):
strings_cap() { grep -aq "$2" "$1" 2>/dev/null; }
strings_cap "$PL_BIN/fx-verbs-server" "fx_build" \
    || skip "staged fx-verbs-server predates fx_build — the payload is stale; re-run tools/stage-guest.sh"
# THE CONTROL-CHANNEL ROUTE must be IN the staged payload (a stale pre-fix
# server would silently run the direct-exec route and the commit assertions
# below would fail unattributably): the fallback banner's marker string.
strings_cap "$PL_BIN/fx-verbs-server" "NO PID1 CONTROL CHANNEL" \
    || skip "staged fx-verbs-server predates the control-channel fx_activate — the payload is stale; re-run tools/stage-guest.sh"

ZB="$PAYLOAD/init-x86_64-musl/bin"
if [ ! -x "$ZB/fx-init" ] || [ "${QEMU_AGENT_REBUILD_INIT:-0}" = 1 ]; then
    echo "=== qemu-agent-slot-inguest: building fx-init's guest binaries (x86_64-linux-musl) ==="
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
    assert_guest_elf "$ZB/$b" "x86-64"
done
# CAPABILITY PROBE, not a ref: the staged fx-activate must carry the src_of
# writer (the store's attribution this gate's whole asymmetry rests on).
grep -aq src_of "$ZB/fx-activate" || {
    skip "staged fx-activate at $ZB predates src_of — the staging froze on an OLD fx-init; rm -rf build/guest-payload/init-x86_64-musl and re-run"
}

# ─── freeze the package sources + the SLOT package set ───────────────────
echo "=== qemu-agent-slot-inguest: freezing package sources ($INIT + its siblings) ==="
SIBS="$(cd "$INIT/.." && pwd)"
DL="$SIBS/datalog-dafsa/zig-out/lib"
[ -f "$DL/libdatalog.so" ] || skip "libdatalog.so missing at $DL"
[ -x "$SIBS/dhake/dhake.com" ] || skip "prebuilt dhake.com missing"

freeze_src() { # freeze_src SRC DST (qemu-agent-observe.sh's shape)
    mkdir -p "$2"
    ( cd "$1" && find . \
        -not -path "./.git/*"       -not -name ".git" \
        -not -path "./build-tmp/*"  -not -name "build-tmp" \
        -not -path "./zig-out/*"    -not -name "zig-out" \
        -not -path "./zig/zig-out/*" \
        -not -path "./zig/.zig-cache/*" -not -name ".zig-cache" \
        -not -path "./zig/.zig-global/*" -not -name ".zig-global" \
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
# THE SLOT SET, path-rewritten to the frozen trees; the oslot entry's GUEST
# path (/fx/disk/agent-src/oslot) stays verbatim — the in-guest build reads
# THE AGENT'S OWN BYTES off the live disk, which is the whole point.
sed -e "s|< Path = \"../../datalog-dafsa\" >|< Path = \"$FROZEN/siblings/datalog-dafsa\" >|" \
    -e "s|< Path = \"../../dhall-c\" >|< Path = \"$FROZEN/siblings/dhall-c\" >|" \
    -e "s|< Path = \"../../fxstore\" >|< Path = \"$FROZEN/siblings/fxstore\" >|" \
    -e "s|< Path = \"../vendor/dhake\" >|< Path = \"$FROZEN/fx-init/vendor/dhake\" >|" \
    -e "s|< Path = \"..\" >|< Path = \"$FROZEN/fx-init\" >|" \
    -e "s|< Path = \"../tests/fixtures/fakesvc\" >|< Path = \"$FROZEN/fx-init/tests/fixtures/fakesvc\" >|" \
    "$SLOTSET" > "$WORK/package-set.dhall" || fail "cannot rewrite the slot package set"
grep -qF "$FROZEN" "$WORK/package-set.dhall" || fail "the slot-set rewrite produced no frozen paths"
if grep -qF '< Path = "..' "$WORK/package-set.dhall"; then
    fail "the slot-set rewrite left relative Path values (in-guest load would fail)"
fi
PKGSET="$WORK/package-set.dhall"
grep -qF "< Path = \"$SLOT_SRC_DIR\" >" "$PKGSET" \
    || fail "the slot entry's guest src path was clobbered by the rewrite"

# the fake-service tree must be .elm-FREE (an .elm in a RUN component's
# source would pollute the 0% arm for a reason that is not the slot)
if find "$FROZEN/fx-init/tests/fixtures/fakesvc" -name '*.elm' | grep -q .; then
    fail "the frozen fakesvc fixture carries .elm files — the 0% arm would measure vendor noise"
fi

# ─── the agent's Osier source ────────────────────────────────────────────
OSIER_SRC="$WORK/Mcp.elm"
cat > "$OSIER_SRC" <<'ELM'
module Mcp exposing (tools, handle)
{- The agent-authored MCP server (Osier source).  This file is the ONLY
   thing the task writes: the deployment pre-declares the slot, the host
   freezes the recipe, and the machine's own builder turns these bytes into
   the component the generation runs — in the guest, on the live store. -}
version : Int
version = 1
tools : List String
tools = [ "fx_echo", "fx_status" ]
handle : String -> String
handle name = "tool:" ++ name ++ ":ok"
ELM
ELM_BYTES=$(wc -c < "$OSIER_SRC" | tr -d ' ')
[ "$ELM_BYTES" -gt 0 ] || fail "the fixture Osier source is empty"

svc_head() {
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
BASE_PKGS='"dhake", "fx-init", "fxctl", "fx-activate", "fake-service"'
heartbeat() {
    echo '{ name = "heartbeat", argv = [ "fakesvc", "ok" ], pkg = Some "fake-service",
            on = "all", restart = Some "always", backoffMs = Some 500,
            probe = None Probe,
            env = None (List { key : Text, value : Text }),
            console = None Text }'
}
agent_svc() { # agent_svc CHARDEV -> the console agent service row
    cat <<DHALL
, { name = "slotagent", argv = [ "/usr/fx-agent/bin/fx-agent", "-p", "write your osier mcp server source, build it in-guest and activate the slot",
                                "--agent", "fx", "--max-turns", "2", "--output", "text" ], pkg = None Text,
            on = "all", restart = Some "never", backoffMs = None Natural,
            probe = None Probe,
            env = Some [ { key = "FX_CHARDEV", value = "$1" },
                         { key = "FX_AGENT_CONFIG_DIR", value = "/usr/fx-agent/cfg" },
                         { key = "FX_AGENT_DATA", value = "$AGENT_DATA" },
                         { key = "HOME", value = "/tmp" }
                       ] : Optional (List { key : Text, value : Text }),
            console = Some "console" }
DHALL
}
# THE FXSTORE EXEC PROBE: a console service running the staged builder's
# --help.  It exits 0, so the bracket stays boot-ok, and its usage — with the
# `facts` capability line — lands on the serial console: the payload's
# static musl artifact EXECUTED under the pinned kernel, proven in the boot
# the loop itself runs in (not on the host).
fxstore_probe_svc() {
    cat <<'DHALL'
, { name = "fxstore-probe", argv = [ "/usr/fx-agent/bin/fxstore", "--help" ], pkg = None Text,
            on = "all", restart = Some "never", backoffMs = None Natural,
            probe = None Probe,
            env = None (List { key : Text, value : Text }),
            console = Some "console" }
DHALL
}
# THE SLOT SERVICE (qemu-agent-slot.sh's shape): NON-console, svc_bin
# resolves to <hash>-oslot/mcp-stub-runner via the pkg'd-row rule.
oslot_svc() {
    cat <<'DHALL'
, { name = "oslot-mcp", argv = [ "mcp-stub-runner" ], pkg = Some "oslot",
            on = "all", restart = Some "always", backoffMs = Some 500,
            probe = None Probe,
            env = None (List { key : Text, value : Text }),
            console = None Text }
DHALL
}
# THE STAGE3 EXEC PROBE (its own boot, below): bare stage3 prints its usage
# and exits 1 — the boot is FAILED BY CONSTRUCTION (the SERVICE-GATE shape);
# no SECCOMP in this kernel means no sandboxed-child shape is provable here,
# and the bare-usage shape proves the EXEC itself.
stage3_probe_svc() {
    cat <<'DHALL'
, { name = "stage3-probe", argv = [ "/usr/fx-agent/bin/stage3" ], pkg = None Text,
            on = "all", restart = Some "never", backoffMs = None Natural,
            probe = None Probe,
            env = None (List { key : Text, value : Text }),
            console = Some "console" }
DHALL
}

# THE BRACKET (the generation boot 1 runs): the slot is NOT in the closure.
{
    svc_head
    cat <<DHALL
in  { hostname = "inguestbox"
    , packages = [ $BASE_PKGS ]
    , users = [ { name = "root", uid = 0, groups = [] : List Text } ]
    , services =
        [ $(heartbeat)
        $(fxstore_probe_svc)
        $(agent_svc /usr/fx-agent/arm.sse)
        ]
    , extraEtc = None (List { path : Text, content : Text })
    , bootGraceMs = Some 30000
    , agentService = Some "slotagent"
    }
DHALL
} > "$WORK/bracket.dhall" || fail "cannot write the bracket config"

# THE SLOT CONFIG (what the agent writes and activates).
{
    svc_head
    cat <<DHALL
in  { hostname = "inguestbox2"
    , packages = [ $BASE_PKGS, "oslot" ]
    , users = [ { name = "root", uid = 0, groups = [] : List Text } ]
    , services =
        [ $(heartbeat)
        $(oslot_svc)
        ]
    , extraEtc = None (List { path : Text, content : Text })
    , bootGraceMs = Some 30000
    , agentService = None Text
    }
DHALL
} > "$WORK/slotconfig.dhall" || fail "cannot write the slot config"

# THE STAGE3-PROBE CONFIG (its own one-generation boot).
{
    svc_head
    cat <<DHALL
in  { hostname = "inguestbox3"
    , packages = [ $BASE_PKGS ]
    , users = [ { name = "root", uid = 0, groups = [] : List Text } ]
    , services =
        [ $(heartbeat)
        $(stage3_probe_svc)
        ]
    , extraEtc = None (List { path : Text, content : Text })
    , bootGraceMs = Some 30000
    , agentService = None Text
    }
DHALL
} > "$WORK/stage3probe.dhall" || fail "cannot write the stage3-probe config"

# THE OVER-WIDE CONFIG (the dedicated refusal boot): 66 distinct services —
# two past PID1's 64-service supervision window (SVC_MAX).  fx-activate
# ACCEPTS it (the activator has no service-count bound; MEASURED: the bound
# lives in init.zig read_store_facts' svc_name_cb) and PUBLISHES it, and
# PID1's activate handler then REFUSES to supervise it: the channel reply is
# `ERR activated version N but REFUSED: service '<name>' is #65 ...` — the
# loud, non-zero refusal the model must see.  Every service rides the
# fake-service package (in the closure already); none ever runs (the refused
# table is freed, nothing starts).
{
    svc_head
    n=1
    printf 'in  { hostname = "inguestwide"\n'
    printf '    , packages = [ %s ]\n' "$BASE_PKGS"
    printf '    , users = [ { name = "root", uid = 0, groups = [] : List Text } ]\n'
    printf '    , services =\n'
    printf '        [ %s\n' "$(heartbeat)"
    n=2
    while [ "$n" -le 66 ]; do
        printf '        , { name = "widesvc%d", argv = [ "fakesvc", "ok" ], pkg = Some "fake-service",\n' "$n"
        printf '            on = "all", restart = Some "never", backoffMs = None Natural,\n'
        printf '            probe = None Probe,\n'
        printf '            env = None (List { key : Text, value : Text }),\n'
        printf '            console = None Text }\n'
        n=$((n + 1))
    done
    printf '        ]\n'
    printf '    , extraEtc = None (List { path : Text, content : Text })\n'
    printf '    , bootGraceMs = Some 30000\n'
    printf '    , agentService = None Text\n'
    printf '    }\n'
} > "$WORK/wideconfig.dhall" || fail "cannot write the over-wide config"
[ -s "$WORK/wideconfig.dhall" ] || fail "the over-wide config is empty"

# ─── the agent pin (qemu-agent-slot.sh's helper, verbatim in substance) ───
agent_pin() { # agent_pin CFG NAME — CFG must declare NAME as its agent ('-' = None)
    _pc="${FX_INIT_CONFIG_CHECK:-$INIT/zig/zig-out/bin/config_check}"
    [ -x "$_pc" ] || fail "agent pin: $_pc missing — build fx-init's zig port (the pin runs the real parser, it does not approximate one)"
    _cfg="$1"; _want="$2"
    _out=$("$_pc" "$_cfg" 2>&1) || { printf '%s\n' "$_out" >&2; fail "agent pin: the substrate refused the payload config $_cfg"; }
    printf '%s\n' "$_out" | grep -q "^agent_service=$_want\$" \
        || fail "agent pin: $_cfg does not declare agent_service=$_want (dump says: $(printf '%s\n' "$_out" | sed -n 's/^agent_service=//p' | head -1))"
    grep -v 'agentService' "$_cfg" > "$WORK/agent-pin-omit.dhall"
    cmp -s "$WORK/agent-pin-omit.dhall" "$_cfg" \
        && fail "agent pin: $_cfg carries no agentService line — the omission mutant could not be built"
    _oout=$("$_pc" "$WORK/agent-pin-omit.dhall" 2>&1) \
        && fail "agent pin: the substrate ACCEPTED $_cfg with agentService OMITTED — the required-field bound is gone (stale config_check?)"
    printf '%s\n' "$_oout" | grep -q "config missing 'agentService'" \
        || fail "agent pin: the omission refusal does not say the field is missing: $_oout"
    if [ "$_want" != "-" ]; then
        python3 - "$_cfg" "$_want" "$WORK/agent-pin-nc.dhall" <<'PYEOF2'
import re, sys
src, name, dst = sys.argv[1], sys.argv[2], sys.argv[3]
txt = open(src).read()
out, hit = [], 0
for row in re.split(r"(?=\{ name =)", txt):
    if ('name = "%s"' % name) in row and 'console = Some "console"' in row:
        row = row.replace('console = Some "console"', 'console = None Text', 1)
        hit += 1
    out.append(row)
if hit != 1:
    sys.exit("agent pin: expected exactly one console row naming %s in %s, found %d"
             % (name, src, hit))
open(dst, "w").write("".join(out))
PYEOF2
        [ -s "$WORK/agent-pin-nc.dhall" ] || fail "agent pin: the non-console mutant could not be built"
        _nout=$("$_pc" "$WORK/agent-pin-nc.dhall" 2>&1) \
            && fail "agent pin: the substrate ACCEPTED a NON-console agent service — the oscillator bound is gone (stale config_check?)"
        printf '%s\n' "$_nout" | grep -q "agentService '$_want'" \
            || fail "agent pin: the non-console refusal does not name '$_want': $_nout"
        echo "agent pin: $(basename "$_cfg") declares agent_service=$_want; the substrate refuses an omitted declaration and a non-console $_want mutant (named)"
    else
        echo "agent pin: $(basename "$_cfg") declares agent_service=- (no agent); the substrate refuses an omitted declaration"
    fi
}
agent_pin "$WORK/bracket.dhall" "slotagent"
agent_pin "$WORK/slotconfig.dhall" "-"
agent_pin "$WORK/stage3probe.dhall" "-"
agent_pin "$WORK/wideconfig.dhall" "-"

CCHK="$INIT/zig/zig-out/bin/config_check"
if [ -x "$CCHK" ]; then
    for c in "$WORK/bracket.dhall" "$WORK/slotconfig.dhall" "$WORK/stage3probe.dhall" \
             "$WORK/wideconfig.dhall"; do
        out=$("$CCHK" "$c" 2>&1) || { echo "$out" >&2; fail "config_check rejected $c"; }
    done
else
    echo "qemu-agent-slot-inguest: WARNING: $CCHK absent — the configs were not parser-checked" >&2
fi

# ─── the payload root (ONE root; ONE loop image) ─────────────────────────
# FX_AGENT_WRITABLE names the agent's whole WRITE surface (the slot's one
# source file + the task config); FX_AGENT_BUILDABLE names the agent's whole
# BUILD surface (exactly the slot package).  Both are HOST-declared facts of
# the deployment, not policies the model negotiates.  (The refusal arm's
# over-wide config is PRE-PLACED on its disk by the host — the gate's own
# debugfs surgery — so the agent's write surface stays exactly these two
# paths; the probe's subject is the ACTIVATION refusal, not the write.)
WIDE_CONFIG=/fx/disk/agent-wide.dhall
WRITABLE="$SLOT_SRC_FILE:$AGENT_CONFIG"
BUILDABLE="oslot"
R="$WORK/root-1"
cp -a "$PAYROOT" "$R" || fail "cannot copy the payload rootdir"
mkdir -p "$R/usr/fx-agent/cfg" || fail "cannot create the agent config dir"
cat > "$R/usr/fx-agent/cfg/config.dhall" <<DHALL
{ agents =
  [ { name = "fx"
    , agent_type = "agent"
    , mcp_servers =
      [ { command = "/usr/fx-agent/bin/fx-verbs-server"
        , args = [] : List Text
        , env = Some { FX_AGENT_WRITABLE = "$WRITABLE"
                     , FX_AGENT_BUILDABLE = "$BUILDABLE"
                     }
        }
      ]
    }
  ]
}
DHALL
[ -s "$R/usr/fx-agent/cfg/config.dhall" ] || fail "cannot write the agent config"

# ─── the fixture (the model, canned) ──────────────────────────────────────
# THE LOOP'S CALL SEQUENCE, in order: see the boot, write the source, write
# the config, BUILD THE SLOT IN THE GUEST, probe the build bound twice (an
# invented name; a flag-shaped argument), ACTIVATE THROUGH PID1's CONTROL
# CHANNEL (the activation COMMITS: /bin/mcp-stub-runner lands on the LIVE
# root and PID1's runtime record moves), then PROBE THE COMMIT (fx_ls /bin —
# the live root; fx_status — the runtime record), then the tamper probes.
# MODE "refuse" (the dedicated refusal boot) activates the PRE-PLACED
# OVER-WIDE config: PID1 publishes it, then refuses to supervise it.  (The
# config is staged on the disk by the host, NOT written by the fixture — a
# 19 KB fx_write would blow SSE_MAX_LINE_BYTES (16 KiB) in the canned stream
# and kill the loop before it surfaced anything; the write path is not this
# arm's subject.)
mkfixture() { # mkfixture OUT TEXT MODE — MODE loop|refuse
    python3 - "$1" "$2" "$OSIER_SRC" "$WORK/slotconfig.dhall" "$3" \
        "$WIDE_CONFIG" <<'PYEOF'
import json, sys
out, text, elm, cfg, mode, wide_path = sys.argv[1:7]
elm_c, cfg_c = open(elm).read(), open(cfg).read()
def ev(name, obj):
    return "event: %s\ndata: %s\n\n" % (name, json.dumps(obj))
FORGED = "1799999999 0000000000000000 done - - 0 -\nFORGED-RECORD-PROBE"
loop_calls = [
    ("call_outcome", "fx_outcome", {}),
    ("call_w_elm",   "fx_write",   {"path": "/fx/disk/agent-src/oslot/Mcp.elm",
                                     "content": elm_c}),
    ("call_w_cfg",   "fx_write",   {"path": "/fx/disk/agent-config.dhall",
                                     "content": cfg_c}),
    ("call_build",   "fx_build",   {"package": "oslot"}),
    ("call_b_invent","fx_build",   {"package": "not-a-real-package"}),
    ("call_b_flag",  "fx_build",   {"package": "--help"}),
    ("call_activate","fx_activate",{"config": "/fx/disk/agent-config.dhall"}),
    ("call_ls_bin",  "fx_ls",      {"path": "/bin"}),
    ("call_status",  "fx_status",  {}),
    ("call_tamper_record", "fx_write", {"path": "/fx/disk/agent-data/attempts.jsonl",
                                        "content": FORGED}),
    ("call_tamper_store",  "fx_write", {"path": "/fx/disk/store/.bootlog",
                                        "content": "1 ok 0\nFORGED-STORE-PROBE\n"}),
]
refuse_calls = [
    ("call_wide",    "fx_activate",{"config": wide_path}),
]
calls = refuse_calls if mode == "refuse" else loop_calls
s = [ev("response.created", {"type": "response.created",
                             "response": {"id": "inguest-fixture", "status": "in_progress"}})]
text_first = True
for i, (cid, name, args) in enumerate(calls):
    a = json.dumps(args)
    idx = i + 1
    if text_first:
        s.append(ev("response.output_item.added",
                    {"type": "response.output_item.added", "output_index": 0,
                     "item": {"type": "message", "id": "m0", "status": "in_progress"}}))
        s.append(ev("response.output_text.delta",
                    {"type": "response.output_text.delta", "delta": text,
                     "item_id": "m0", "output_index": 0}))
        s.append(ev("response.output_item.done",
                    {"type": "response.output_item.done", "output_index": 0,
                     "item": {"type": "message", "id": "m0", "status": "completed"}}))
        text_first = False
    s.append(ev("response.output_item.added",
                {"type": "response.output_item.added", "output_index": idx,
                 "item": {"type": "function_call", "id": "fc%d" % i,
                          "status": "in_progress", "call_id": cid,
                          "name": name, "arguments": ""}}))
    s.append(ev("response.function_call_arguments.delta",
                {"type": "response.function_call_arguments.delta",
                 "delta": a, "item_id": "fc%d" % i, "output_index": idx}))
    s.append(ev("response.output_item.done",
                {"type": "response.output_item.done", "output_index": idx,
                 "item": {"type": "function_call", "id": "fc%d" % i,
                          "status": "completed", "call_id": cid, "name": name,
                          "arguments": a}}))
s.append(ev("response.completed",
            {"type": "response.completed",
             "response": {"id": "inguest-fixture", "status": "completed"}}))
open(out, "w").write("".join(s))
PYEOF
}
TEXT_MARKER="SLOT-AGENT-RAN-$MARKER"
mkfixture "$R/usr/fx-agent/arm.sse" "$TEXT_MARKER" loop
for pat in 'fx_write' 'fx_build' 'fx_activate' 'FORGED-STORE-PROBE'; do
    grep -q "$pat" "$R/usr/fx-agent/arm.sse" || fail "the fixture has no $pat call"
done
_nfb=$(grep -c '"name": "fx_build"' "$R/usr/fx-agent/arm.sse" || true)
[ "$_nfb" = "6" ] \
    || fail "the fixture does not carry three fx_build calls x2 events each (got $_nfb name events)"

# ─── provisioning (toolchain-free; the deployment's ground-laying) ────────
echo "=== qemu-agent-slot-inguest: provisioning the stores (toolchain-free) ==="
export FX_SIBLINGS="${FX_SIBLINGS:-$SIBS}"
cp "$SIBS/dhake/dhake.com" "$WORK/dhake.com"; chmod +x "$WORK/dhake.com"
"$WORK/dhake.com" --assimilate || fail "dhake --assimilate failed"
file "$WORK/dhake.com" 2>/dev/null | grep -q 'statically linked' || skip "dhake.com did not assimilate to a static ELF"
( cd "$INIT" && zig cc -target x86_64-linux-musl -std=gnu11 -O2 -static \
    -o "$WORK/fakesvc" tests/fixtures/fakesvc/fakesvc.c ) || fail "zig cc fakesvc failed"
assert_guest_elf "$WORK/fakesvc" "x86-64"

provision() { # provision STOREDIR -> fills the base-package dirs
    _st=$1
    mkdir -p "$_st" || fail "cannot create $_st"
    PATHS=$(LD_LIBRARY_PATH="$DL" "$ZB/activate_paths" \
        --store "$_st" --package-set "$PKGSET" \
        dhake fx-init fxctl fx-activate fake-service) || fail "activate_paths failed ($_st)"
    [ -n "$PATHS" ] || fail "activate_paths printed no closure ($_st)"
    echo "$PATHS" | while IFS= read -r pd; do
        mkdir -p "$_st/$pd" || exit 1
        case "$pd" in
            *-fx-init)      cp "$ZB/fx-init"     "$_st/$pd/fx-init";     chmod 755 "$_st/$pd/fx-init" ;;
            *-fxctl)        cp "$ZB/fxctl"       "$_st/$pd/fxctl";       chmod 755 "$_st/$pd/fxctl" ;;
            *-fx-activate)  cp "$ZB/fx-activate" "$_st/$pd/fx-activate"; chmod 755 "$_st/$pd/fx-activate" ;;
            *-fake-service) cp "$WORK/fakesvc"   "$_st/$pd/fakesvc";     chmod 755 "$_st/$pd/fakesvc" ;;
            *-dhake)        cp "$WORK/dhake.com" "$_st/$pd/dhake.com";   chmod 755 "$_st/$pd/dhake.com" ;;
            *)              : > "$_st/$pd/.provisioned-by-qemu-agent-slot-inguest" ;;
        esac
    done
}

activate_host() { # activate_host STORE CFG -> "activated <hash> as version N"
    LD_LIBRARY_PATH="$DL" "$ZB/fx-activate" --store "$1" \
        --package-set "$PKGSET" --config "$2" 2>&1
}
version_of() { sed -n 's/.*as version \([0-9][0-9]*\).*/\1/p' | head -1; }
image() { # image ROOTDIR LISTFILE OUT STORE
    sh "$INIT/tests/mkinitramfs.sh" -s "$4" -r "$1" -k "$KERNEL" -o "$3" -l "$2" -p "$PKGSET" \
        || fail "mkinitramfs failed ($3)"
}

# ─── disk + boot helpers (qemu-agent-slot.sh's shapes) ───────────────────
qemu_pid=""
boot() { # boot IMG CONLOG DISK
    _img=$1 _con=$2; DISK=$3
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
# One tool call's reply content out of a session transcript (JSONL): the
# LIVE-ROOT and RUNTIME-RECORD probes read exactly their own reply, never a
# whole-transcript grep (the fx_build reply names mcp-stub-runner in its own
# recipe bytes, so a global grep would pass for a reason that is not /bin).
tool_reply() { # tool_reply TRANSCRIPT CALLID -> that tool call's reply content
    python3 - "$1" "$2" <<'PYLS'
import json, sys
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        o = json.loads(line)
    except ValueError:
        continue
    if o.get("role") == "tool" and o.get("tool_call_id") == sys.argv[2]:
        print(o.get("content", ""))
PYLS
}
new_disk() {
    qemu-img create -q "$1" 512M || fail "qemu-img create ($1) failed"
    "$MKE2FS" -q -t ext4 -J size=4 "$1" >/dev/null 2>&1 || fail "mke2fs ($1) failed"
}
read_from_disk() { "$DEBUGFS" -R "dump $1 $2" "$DISK" >/dev/null 2>&1 </dev/null; }
# e2fsck is used EXACTLY ONCE per disk, BEFORE its first boot (the initial
# mkfs settle) — never between boots: between-boot surgery is the path this
# gate exists to disprove.  Raw debugfs READS need no clean fs (MEASURED,
# qemu-agent-slot.sh's pre-fsck read-back).
fsck_once() {
    "$E2FSCK" -fy "$1" >"$WORK/e2fsck-$2.log" 2>&1
    _rc=$?
    [ "$_rc" -le 3 ] || { tail -8 "$WORK/e2fsck-$2.log" >&2; fail "e2fsck -fy failed (rc=$_rc) on $1"; }
    return 0
}
disk_mkdirs() { # disk_mkdirs DISK DIR...
    _dsk=$1; shift
    : > "$WORK/dbg-cmds"
    for d in "$@"; do echo "mkdir $d" >> "$WORK/dbg-cmds"; done
    "$DEBUGFS" -w -f "$WORK/dbg-cmds" "$_dsk" >/dev/null 2>&1 \
        || fail "debugfs mkdir failed (the slot seat)"
    for d in "$@"; do
        "$DEBUGFS" -R "ls -l $d" "$_dsk" >/dev/null 2>&1 || fail "debugfs cannot see $d after mkdir"
    done
}
disk_put() { # disk_put DISK LOCALFILE GUESTPATH (guest path from the fs root)
    "$DEBUGFS" -w -R "write $2 $3" "$1" >/dev/null 2>&1 \
        || fail "debugfs write failed for $3"
    "$DEBUGFS" -R "cat $3" "$1" >/dev/null 2>&1 \
        || fail "debugfs cannot read back $3 after write"
}
# read a whole directory TREE off the disk, per file (rdump chowns => EPERM;
# every debugfs child gets < /dev/null — MEASURED in qemu-agent-slot.sh).
disk_read_tree() { # disk_read_tree DISK INPATH OUTDIR
    _dsk=$1 _in=$2 _out=$3
    mkdir -p "$_out"
    disk_read_tree_rec() {
        _p=$1 _o=$2
        mkdir -p "$_o"
        _listing=$("$DEBUGFS" -R "ls -l $_p" "$_dsk" 2>/dev/null </dev/null) || return 0
        printf '%s\n' "$_listing" | while IFS= read -r _ln; do
            _name=$(printf '%s\n' "$_ln" | awk '{ $1=$2=$3=$4=$5=$6=$7=$8=""; sub(/^ +/,""); print }')
            [ -n "$_name" ] || continue
            case "$_name" in .|..|lost+found) continue ;; esac
            _mode=$(printf '%s\n' "$_ln" | awk '{print $2}')
            _child="$_p/$_name"
            case "$_mode" in
                4*) _sp=$_p _so=$_o _sl=$_listing
                    mkdir -p "$_o/$_name"
                    disk_read_tree_rec "$_child" "$_o/$_name" </dev/null
                    _p=$_sp _o=$_so _listing=$_sl ;;
                *)  "$DEBUGFS" -R "dump $_child $_o/$_name" "$_dsk" >/dev/null 2>&1 </dev/null || : ;;
            esac
        done
    }
    disk_read_tree_rec "$_in" "$_out" </dev/null
}

run_oracle() { # run_oracle STOREDIR [ASOF] -> oracle stdout
    if [ $# -ge 2 ]; then
        FXSTORE_BIN="$FXSTORE" "$OSIER" --store "$1" --package-set "$PKGSET" --as-of "$2"
    else
        FXSTORE_BIN="$FXSTORE" "$OSIER" --store "$1" --package-set "$PKGSET"
    fi
}
field() { sed -n "s/^$2 //p" "$1" | head -1; }

# ═══ PHASE A — the stage3 EXEC PROOF (its own one-generation boot) ═══════
echo "=== qemu-agent-slot-inguest: phase A — the stage3 usage boot (exec proof) ==="
STORE3="$WORK/store3"
provision "$STORE3"
OUT_S3=$(activate_host "$STORE3" "$WORK/stage3probe.dhall") || fail "activate stage3probe failed: $OUT_S3"
V_S3=$(echo "$OUT_S3" | version_of); [ -n "$V_S3" ] || fail "cannot parse v_S3 from: $OUT_S3"
image "$R" "$WORK/img3.list" "$WORK/img3.cpio.gz" "$STORE3"
FXD3=$(ls -d "$STORE3"/*-fx-init | head -1)
RDINIT="/fx/store/$(basename "$FXD3")/fx-init"
DISK3="$WORK/disk3.img"; new_disk "$DISK3"; fsck_once "$DISK3" a
boot "$WORK/img3.cpio.gz" "$WORK/s3boot.log" "$DISK3"
cp "$WORK/s3boot.log" "$EVID/stage3-console.log"
# the usage line proves the static artifact EXECUTED under the pinned kernel
# (a host run proves nothing — the i386-LuaJIT lesson).
grep -q 'stage3: usage: stage3 PROMISES LANDLOCK_SPEC' "$WORK/s3boot.log" \
    || { tail -40 "$WORK/s3boot.log"; halt; fail "phase A: stage3's usage never printed in the guest — the staged artifact did not exec"; }
grep -q 'fx-init: boot-FAILED v'"$V_S3" "$WORK/s3boot.log" \
    || echo "qemu-agent-slot-inguest: NOTE — the stage3-probe boot did not read FAILED (verdict: $(grep -o 'boot-[A-Z]* v[0-9]*' "$WORK/s3boot.log" | tail -1))"
halt
# the DISK's own record: the failed verdict reached the platter (the exit
# propagated into PID1's boot decision — SERVICE-GATE's reasoning).
read_from_disk "/store/.bootlog" "$WORK/s3-bootlog.txt"
grep -q "^$V_S3 failed " "$WORK/s3-bootlog.txt" \
    || { cat "$WORK/s3-bootlog.txt" 2>/dev/null; fail "phase A: the disk bootlog does not record v$V_S3 failed — the exit did not reach PID1's verdict"; }
echo "qemu-agent-slot-inguest: phase A GREEN — stage3 exec'd in-guest (usage on console); boot-FAILED v$V_S3 recorded on the disk"

if [ "${INGUEST_SKIP_BOOT:-0}" = "1" ]; then
    echo "qemu-agent-slot-inguest: INGUEST_SKIP_BOOT=1 — phase A done, loop boots skipped"
    echo "qemu-agent-slot-inguest: PASS (stage-only)"
    exit 0
fi

# ═══ PHASE B — boot 1: THE LOOP (write -> BUILD IN-GUEST -> activate) ════
echo "=== qemu-agent-slot-inguest: phase B — boot 1: the agent writes, BUILDS IN-GUEST, activates ==="
STORE="$WORK/store"
provision "$STORE"
OUT_B=$(activate_host "$STORE" "$WORK/bracket.dhall") || fail "activate bracket failed: $OUT_B"
V_B=$(echo "$OUT_B" | version_of); [ -n "$V_B" ] || fail "cannot parse v_B from: $OUT_B"
echo "$OUT_B"
image "$R" "$WORK/img1.list" "$WORK/img1.cpio.gz" "$STORE"
for want in usr/fx-agent/bin/fx-agent usr/fx-agent/bin/fx-verbs-server \
            usr/fx-agent/bin/fxstore usr/fx-agent/bin/stage3 \
            usr/fx-agent/cfg/config.dhall usr/fx-agent/arm.sse; do
    grep -qx "$want" "$WORK/img1.list" || fail "the loop image does not carry $want"
done
grep -qx "usr/fx/package-set.dhall" "$WORK/img1.list" \
    || fail "the image does not carry the frozen package set (mkinitramfs -p)"
FXD=$(ls -d "$STORE"/*-fx-init | head -1)
RDINIT="/fx/store/$(basename "$FXD")/fx-init"

DISK="$WORK/disk.img"; new_disk "$DISK"; fsck_once "$DISK" b
# THE SLOT SEAT (the deployment pre-creates the dir; fx_write cannot mkdir)
disk_mkdirs "$DISK" /agent-src /agent-src/oslot

# THE IMAGE IS FROZEN FROM HERE ON: sha256 before boot 1, and byte-compared
# before boot 2.  Between the two boots the host touches NEITHER the image
# NOR the disk (no e2fsck, no debugfs -w, no rebuild — read the script).
IMG_SHA=$(sha256sum "$WORK/img1.cpio.gz" | awk '{print $1}')

boot "$WORK/img1.cpio.gz" "$WORK/boot1.log" "$DISK"
cp "$WORK/boot1.log" "$EVID/boot1-console.log"
grep -n 'disk store mounted\|boot-ok\|boot-FAILED\|SLOT-AGENT-RAN\|fxstore' "$WORK/boot1.log" | head -12
# The boot STARTED in the bracket (disk CURRENT was v$V_B at mount).  The
# bracket's OWN verdict may never fire: the agent can activate INSIDE the
# grace window, and the channel route's handler then re-arms the decision for
# the NEW generation — the console's verdict (asserted below, after the
# record is read: boot-ok v$V_SLOT) belongs to the re-armed window.  (The
# pre-2026-10 durable-only route never re-armed anything, so the bracket's
# verdict always fired — that shape is pinned by the BEFORE arm.)
grep -q "fx-init: disk store mounted (current v$V_B)" "$WORK/boot1.log" \
    || { tail -30 "$WORK/boot1.log"; halt; fail "boot 1: the machine did not come up in the bracket v$V_B"; }
grep -qF "$TEXT_MARKER" "$WORK/boot1.log" \
    || { tail -40 "$WORK/boot1.log"; halt; fail "boot 1: the agent never ran (no '$TEXT_MARKER')"; }
# THE FXSTORE EXEC PROOF, ON THIS BOOT'S CONSOLE: the probe service ran the
# staged static binary and its usage reached the serial line.
grep -q 'fxstore — content-addressed build store' "$WORK/boot1.log" \
    || { tail -40 "$WORK/boot1.log"; halt; fail "boot 1: the fxstore --help usage is not on the console — the staged builder did not exec in-guest"; }
grep -q 'fxstore facts' "$WORK/boot1.log" \
    || { tail -40 "$WORK/boot1.log"; halt; fail "boot 1: the staged fxstore predates 'facts' — the payload binary is stale"; }
halt
echo "qemu-agent-slot-inguest: boot 1 console GREEN — bracket v$V_B ok; fxstore usage on the console (exec proof); the agent ran"

# RAW STATE reads (pre-fsck, read-only — the platter the guest wrote):
# 1. the writes landed and the refusals fired
read_from_disk "/agent-src/oslot/Mcp.elm" "$WORK/b1-elm.txt"
cmp -s "$WORK/b1-elm.txt" "$OSIER_SRC" \
    || { diff "$OSIER_SRC" "$WORK/b1-elm.txt" | head -10; fail "boot 1: the agent's Osier source is not byte-identical on the disk"; }
read_from_disk "/agent-config.dhall" "$WORK/b1-cfg.txt"
cmp -s "$WORK/b1-cfg.txt" "$WORK/slotconfig.dhall" \
    || fail "boot 1: the slot config is not byte-identical on the disk"
read_from_disk "/agent-data/attempts.jsonl" "$WORK/b1-record.txt"
[ -s "$WORK/b1-record.txt" ] || fail "boot 1: no durable record on the disk"
grep -q " attempt " "$WORK/b1-record.txt" \
    || { cat "$WORK/b1-record.txt"; fail "boot 1: no activation attempt recorded — the in-boot activation never ran"; }
grep -q "FORGED-RECORD-PROBE" "$WORK/b1-record.txt" \
    && fail "boot 1: forged content REACHED the record"
V_SLOT=$(sed -n 's/.* result .* \([0-9][0-9]*\).*/\1/p' "$WORK/b1-record.txt" | head -1)
[ -n "$V_SLOT" ] || { cat "$WORK/b1-record.txt"; fail "boot 1: no recorded activation RESULT on the disk"; }
[ "$V_SLOT" -gt "$V_B" ] || fail "boot 1: the slot generation v$V_SLOT is not above the bracket v$V_B"

# 2. THE IN-GUEST BUILD'S OWN OUTPUT, from the agent's transcript on the disk
SID=$( "$DEBUGFS" -R "ls -p /agent-data/sessions" "$DISK" 2>/dev/null \
       | sed -n 's|^/[0-9]*/[0-9]*/[0-9]*/[0-9]*/\([^/.][^/]*\)/*$|\1|p' | head -1 )
[ -n "$SID" ] || fail "boot 1: no session on the disk"
read_from_disk "/agent-data/sessions/$SID/messages.jsonl" "$WORK/b1-transcript.jsonl"
cp "$WORK/b1-transcript.jsonl" "$EVID/boot1-transcript.jsonl"
# the BUILD reply: exit 0, fxstore's own lines, and the LOUD fallback VISIBLE
grep -q 'fx_build' "$WORK/b1-transcript.jsonl" \
    || fail "boot 1: the transcript carries no fx_build call — the fixture's build step never dispatched"
grep -q 'fxstore: building oslot' "$WORK/b1-transcript.jsonl" \
    || { grep -o 'fx_build.\{0,200\}' "$WORK/b1-transcript.jsonl" | head -3; \
         fail "boot 1: fxstore's own 'building oslot' line is not in the fx_build reply — the builder did not run (or did not run in-guest)"; }
grep -q 'fxstore: built ' "$WORK/b1-transcript.jsonl" \
    || fail "boot 1: fxstore reports no built store path in the fx_build reply"
grep -q 'WARNING: bwrap not found' "$WORK/b1-transcript.jsonl" \
    || { grep -o 'fx_build.\{0,200\}' "$WORK/b1-transcript.jsonl" | head -3; \
         fail "boot 1: the LOUD non-hermetic fallback warning is NOT in the fx_build evidence — the bwrap-absent path must be VISIBLE, not silenced"; }
grep -q 'NON-HERMETIC' "$WORK/b1-transcript.jsonl" \
    || fail "boot 1: the fallback warning does not say NON-HERMETIC"
# THE BOUND: both probes refused, naming the host-declared set
grep -q "not in the host-declared buildable set" "$WORK/b1-transcript.jsonl" \
    || fail "boot 1: no fx_build refusal naming the buildable set — the invented-package probe never fired or was not refused"
grep -q 'FX_AGENT_BUILDABLE' "$WORK/b1-transcript.jsonl" \
    || fail "boot 1: the fx_build refusal does not name FX_AGENT_BUILDABLE"
grep -q 'not a bare package name' "$WORK/b1-transcript.jsonl" \
    || fail "boot 1: the flag-shaped fx_build probe was not refused as a non-bare name"
# the writes + the activation + the tamper refusals
grep -q "bytes to $SLOT_SRC_FILE" "$WORK/b1-transcript.jsonl" \
    || fail "boot 1: the agent's SOURCE write was refused — the writable set broke the task's one legitimate source write"
# THE ROUTE: the reply is PID1's own channel line ("activated version N" —
# the handler's data line), NOT fx-activate's "as version" child line: the
# direct-exec route's marker must be ABSENT.
grep -q "activated version $V_SLOT" "$WORK/b1-transcript.jsonl" \
    || { grep -o 'fx_activate.\{0,120\}' "$WORK/b1-transcript.jsonl" | head -3; \
         fail "boot 1: the fx_activate reply does not report 'activated version $V_SLOT' (PID1's channel reply)"; }
grep -q " as version " "$WORK/b1-transcript.jsonl" \
    && fail "boot 1: the activation took the DIRECT-EXEC route (fx-activate's own 'as version' reply) — the control channel was bypassed"
# THE COMMIT, ON THE LIVE ROOT: the generation's install fact materializes
# /bin/mcp-stub-runner via the hot-apply (run_dhake on the running root, no
# reboot).  The CONTROL first: the fx_ls reply is exit=0 AND lists the
# bracket's own /bin (dhake, shipped since v_B) — so mcp-stub-runner's
# ABSENCE in the BEFORE arm below is a real absence, never a failed probe.
# The check reads ONLY the call_ls_bin reply (the fx_build reply also names
# mcp-stub-runner in its recipe bytes — a global grep would pass vacuously).
LS_BIN_AFTER=$(tool_reply "$WORK/b1-transcript.jsonl" call_ls_bin)
[ -n "$LS_BIN_AFTER" ] || fail "boot 1: no call_ls_bin tool reply in the transcript"
printf '%s\n' "$LS_BIN_AFTER" | grep -q '^exit=0' \
    || { printf '%s\n' "$LS_BIN_AFTER" | head -5; \
         fail "boot 1: the fx_ls /bin listing did not succeed (exit!=0) — the commit assertion cannot stand on it"; }
printf '%s\n' "$LS_BIN_AFTER" | grep -q 'dhake' \
    || { printf '%s\n' "$LS_BIN_AFTER" | head -5; \
         fail "boot 1: the fx_ls /bin listing carries no dhake entry (the bracket's own /bin) — the commit assertion cannot stand on it"; }
printf '%s\n' "$LS_BIN_AFTER" | grep -q 'mcp-stub-runner' \
    || { printf '%s\n' "$LS_BIN_AFTER" | head -8; \
         fail "boot 1: /bin/mcp-stub-runner is NOT on the LIVE root after fx_activate — the activation did not COMMIT (no hot-apply)"; }
# THE RUNTIME RECORD, THROUGH THE MODEL'S OWN VERB: fx_status (fxctl --fifo
# status over PID1's channel) reports generation_current = the new version —
# the rt_set_generation_current the handler wrote.
STATUS_AFTER=$(tool_reply "$WORK/b1-transcript.jsonl" call_status)
[ -n "$STATUS_AFTER" ] || fail "boot 1: no call_status tool reply in the transcript"
printf '%s\n' "$STATUS_AFTER" | grep -q '^exit=0' \
    || { printf '%s\n' "$STATUS_AFTER" | head -5; \
         fail "boot 1: fx_status failed in-guest — the fifo transport for the fast fxctl verbs is broken"; }
printf '%s\n' "$STATUS_AFTER" | grep -A1 '^generation_current:$' | grep -q "  $V_SLOT\$" \
    || { printf '%s\n' "$STATUS_AFTER" | head -12; \
         fail "boot 1: fx_status's generation_current is not v$V_SLOT — the runtime record did not move to the activated generation"; }
# THE RE-ARM: the console carries a SECOND boot verdict — boot-ok for the NEW
# generation, in the SAME boot (the re-armed grace window judged it).  The
# bracket's own boot-ok v$V_B is already asserted above.
grep -q "fx-init: boot-ok v$V_SLOT" "$WORK/boot1.log" \
    || { grep -n 'boot-ok\|boot-FAILED' "$WORK/boot1.log" | head -5; \
         fail "boot 1: no 'boot-ok v$V_SLOT' on the console — the activation did not RE-ARM the boot decision for the new generation"; }
grep -q 'fx_write REFUSED' "$WORK/b1-transcript.jsonl" \
    || fail "boot 1: no in-guest fx_write refusal — the write-bound probes never fired"
_nref=$(grep -c 'fx_write REFUSED' "$WORK/b1-transcript.jsonl" || true)
[ "$_nref" -ge 2 ] \
    || fail "boot 1: expected BOTH the record and the store tamper probes refused, got $_nref refusal(s)"

# 3. THE STORE THE GUEST ITSELF WROTE: the slot dirs exist ON THE DISK
"$DEBUGFS" -R 'ls -p /store' "$DISK" 2>/dev/null </dev/null \
    | sed -n 's|^/[0-9]*/[0-9]*/[0-9]*/[0-9]*/\([^/.][^/]*\)/*$|\1|p' > "$WORK/b1-store-listing.txt"
grep -q -- '-oslot$' "$WORK/b1-store-listing.txt" \
    || { cat "$WORK/b1-store-listing.txt"; fail "boot 1: no <hash>-oslot dir on the disk — the in-guest build wrote nothing"; }
grep -q -- '-oslot-src$' "$WORK/b1-store-listing.txt" \
    || { cat "$WORK/b1-store-listing.txt"; fail "boot 1: no <src_hash>-oslot-src clean-source dir on the disk"; }
SLOT_DIRNAME=$(grep -- '-oslot$' "$WORK/b1-store-listing.txt" | grep -v -- '-oslot-src$' | head -1)
SLOT_SRCNAME=$(grep -- '-oslot-src$' "$WORK/b1-store-listing.txt" | head -1)
SLOT_HASH=$(printf '%s\n' "$SLOT_DIRNAME" | sed 's|^\([0-9a-f]\{64\}\)-oslot$|\1|')
SLOT_SRC_HASH=$(printf '%s\n' "$SLOT_SRCNAME" | sed 's|^\([0-9a-f]\{64\}\)-oslot-src$|\1|')
[ "${#SLOT_HASH}" = "64" ] || fail "boot 1: cannot parse the oslot derivation hash from '$SLOT_DIRNAME'"
read_from_disk "/store/$SLOT_DIRNAME/Mcp.elm" "$WORK/b1-built-elm.txt"
cmp -s "$WORK/b1-built-elm.txt" "$OSIER_SRC" \
    || fail "boot 1: the in-guest-built Mcp.elm is not the agent's bytes"
read_from_disk "/store/$SLOT_DIRNAME/mcp-stub-runner" "$WORK/b1-runner.sh"
head -1 "$WORK/b1-runner.sh" | grep -q '^#!/usr/bin/busybox sh$' \
    || fail "boot 1: the built runner is not a #!/usr/bin/busybox sh script"
grep -q 'STUB' "$WORK/b1-runner.sh" \
    || fail "boot 1: the built runner does not say STUB in its own bytes"
# CURRENT is the slot generation the GUEST activated
read_from_disk "/store/.db/snapshots/CURRENT" "$WORK/b1-current.txt"
[ "$(tr -dc '0-9' < "$WORK/b1-current.txt")" = "$V_SLOT" ] \
    || fail "boot 1: the disk store's CURRENT ($(cat "$WORK/b1-current.txt")) is not the slot generation v$V_SLOT"
echo "qemu-agent-slot-inguest: boot 1 GREEN — written, BUILT IN-GUEST ($SLOT_DIRNAME + $SLOT_SRCNAME), activated v$V_SLOT; bound probes refused; tamper probes refused ($_nref)"

# ═══ PHASE B0 — THE ASYMMETRY'S BEFORE HALF (the pinned pre-fix server) ══
# THE DELIVERABLE: the SAME loop run against the PRE-FIX verb server (the
# git-pinned revision this change landed on top of) PUBLISHES the generation
# to the store but does NOT COMMIT it to the live root — /bin/mcp-stub-runner
# is absent from the fx_ls listing while disk CURRENT holds the new version.
# The pin is a FIXED revision, never HEAD's position; guarded with
# cat-file -e; and cmp-proven to DIFFER from the working tree (an identical
# extract would make every assertion below vacuous).
PIN_REV="${FX_VERBS_PIN_REV:-be2fbd1}"
if ! git -C "$REPO" cat-file -e "$PIN_REV^{commit}" 2>/dev/null; then
    fail "the pinned pre-fix revision $PIN_REV is absent (git fetch it) — the asymmetry's BEFORE half cannot run, and passing without it would be a lie"
fi
git -C "$REPO" cat-file blob "$PIN_REV:tools/fx-verbs-server.c" \
    > "$WORK/before-fx-verbs-server.c" 2>/dev/null \
    || fail "cannot extract $PIN_REV:tools/fx-verbs-server.c"
if cmp -s "$WORK/before-fx-verbs-server.c" "$REPO/tools/fx-verbs-server.c"; then
    fail "the pinned extract is IDENTICAL to the working tree — the BEFORE arm would re-test the fixed server (vacuous asymmetry)"
fi
# The pinned server's own `#include "llm2/outcome.h"` predates the src/llm2 ->
# src/agent rename: resolve it onto the CURRENT reader via a scratch include
# dir that carries the historical spelling (copies, so the pin stays verbatim).
BINC="$WORK/inc/llm2"
mkdir -p "$BINC" || fail "cannot create the pin include dir"
cp "$REPO/src/agent/outcome.c" "$REPO/src/agent/outcome.h" "$BINC/" \
    || fail "cannot stage the current outcome reader for the pinned server"
echo "=== qemu-agent-slot-inguest: phase B0 — building the PRE-FIX server ($PIN_REV, cmp-proven to differ) ==="
( cd "$REPO" && zig cc -target x86_64-linux-musl -static -s -std=c11 -O2 -Wall -Wextra \
    -I"$WORK/inc" -Isrc -Isrc/vendor/yyjson -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE \
    -o "$WORK/fx-verbs-server.before" \
    "$WORK/before-fx-verbs-server.c" src/agent/outcome.c src/vendor/yyjson/yyjson.c ) \
    || fail "cannot build the pre-fix server"
assert_guest_elf "$WORK/fx-verbs-server.before" "x86-64"
strings_cap "$WORK/fx-verbs-server.before" "fx_build" \
    || fail "the pinned pre-fix server predates fx_build — the pin is the wrong revision"
if strings_cap "$WORK/fx-verbs-server.before" "NO PID1 CONTROL CHANNEL"; then
    fail "the pinned pre-fix server already carries the control-channel route — the pin is the wrong revision"
fi

# the BEFORE arm's root: the SAME payload with the server SWAPPED, and the
# swap ASSERTED (sha256 of the staged binary == the binary built above) — the
# artifact this arm runs is provably the one just built, never a stale cache.
RB="$WORK/root-before"
cp -a "$PAYROOT" "$RB" || fail "cannot copy the payload rootdir (before arm)"
cp "$WORK/fx-verbs-server.before" "$RB/usr/fx-agent/bin/fx-verbs-server" || fail "cannot swap the before server"
chmod 755 "$RB/usr/fx-agent/bin/fx-verbs-server"
[ "$(sha256sum "$RB/usr/fx-agent/bin/fx-verbs-server" | awk '{print $1}')" \
  = "$(sha256sum "$WORK/fx-verbs-server.before" | awk '{print $1}')" ] \
    || fail "the before arm's staged server is not the binary this gate built"
mkdir -p "$RB/usr/fx-agent/cfg" || fail "cannot create the before arm's cfg dir"
cp "$R/usr/fx-agent/cfg/config.dhall" "$RB/usr/fx-agent/cfg/config.dhall" || fail "cannot copy the agent config"
mkfixture "$RB/usr/fx-agent/arm.sse" "$TEXT_MARKER" loop

STORE0="$WORK/store-before"
provision "$STORE0"
OUT_B0=$(activate_host "$STORE0" "$WORK/bracket.dhall") || fail "activate before-bracket failed: $OUT_B0"
V_B0=$(echo "$OUT_B0" | version_of); [ -n "$V_B0" ] || fail "cannot parse v_B0 from: $OUT_B0"
image "$RB" "$WORK/imgb.list" "$WORK/imgb.cpio.gz" "$STORE0"
FXD0=$(ls -d "$STORE0"/*-fx-init | head -1)
RDINIT_SAVED="$RDINIT"
RDINIT="/fx/store/$(basename "$FXD0")/fx-init"
DISKB="$WORK/disk-before.img"; new_disk "$DISKB"; fsck_once "$DISKB" b
disk_mkdirs "$DISKB" /agent-src /agent-src/oslot
boot "$WORK/imgb.cpio.gz" "$WORK/bootb.log" "$DISKB"
cp "$WORK/bootb.log" "$EVID/boot-before-console.log"
grep -q "fx-init: boot-ok v$V_B0" "$WORK/bootb.log" \
    || { tail -30 "$WORK/bootb.log"; halt; fail "before arm: want boot-ok v$V_B0"; }
grep -qF "$TEXT_MARKER" "$WORK/bootb.log" \
    || { tail -40 "$WORK/bootb.log"; halt; fail "before arm: the agent never ran"; }
halt
read_from_disk "/agent-data/attempts.jsonl" "$WORK/b0-record.txt"
[ -s "$WORK/b0-record.txt" ] || fail "before arm: no durable record on the disk"
V_SLOT0=$(sed -n 's/.* result .* \([0-9][0-9]*\).*/\1/p' "$WORK/b0-record.txt" | head -1)
[ -n "$V_SLOT0" ] || { cat "$WORK/b0-record.txt"; fail "before arm: no recorded activation RESULT"; }
[ "$V_SLOT0" -gt "$V_B0" ] || fail "before arm: the activation did not publish above the bracket"
SID0=$( "$DEBUGFS" -R "ls -p /agent-data/sessions" "$DISKB" 2>/dev/null \
        | sed -n 's|^/[0-9]*/[0-9]*/[0-9]*/[0-9]*/\([^/.][^/]*\)/*$|\1|p' | head -1 )
[ -n "$SID0" ] || fail "before arm: no session on the disk"
read_from_disk "/agent-data/sessions/$SID0/messages.jsonl" "$WORK/b0-transcript.jsonl"
cp "$WORK/b0-transcript.jsonl" "$EVID/boot-before-transcript.jsonl"
# 1. the OLD route's marker: fx-activate's own "as version" reply
grep -q " as version $V_SLOT0" "$WORK/b0-transcript.jsonl" \
    || { grep -o 'fx_activate.\{0,160\}' "$WORK/b0-transcript.jsonl" | head -3; \
         fail "before arm: the reply is not fx-activate's own 'as version $V_SLOT0' — the pinned server did not take the direct-exec route"; }
# 2. THE ABSENCE: the SAME fx_ls probe SUCCEEDED (dhake listed) but
#    mcp-stub-runner is NOT in ITS listing — PUBLISHED, NOT COMMITTED.  This
#    is the asymmetry's BEFORE half; the AFTER half is asserted on boot 1
#    above.  The check reads ONLY the call_ls_bin tool reply (tool_reply):
#    the fx_build reply ALSO contains the string (the recipe's own heredoc
#    writes the file), so a whole-transcript grep would fail for a reason
#    that is not the live root.
LS_BIN_BEFORE=$(tool_reply "$WORK/b0-transcript.jsonl" call_ls_bin)
[ -n "$LS_BIN_BEFORE" ] || fail "before arm: no call_ls_bin tool reply in the transcript"
printf '%s\n' "$LS_BIN_BEFORE" | grep -q '^exit=0' \
    || { printf '%s\n' "$LS_BIN_BEFORE" | head -5; \
         fail "before arm: the fx_ls /bin listing did not succeed (exit!=0) — the absence assertion below would be vacuous"; }
printf '%s\n' "$LS_BIN_BEFORE" | grep -q 'dhake' \
    || { printf '%s\n' "$LS_BIN_BEFORE" | head -5; \
         fail "before arm: the fx_ls /bin listing carries no dhake entry (the bracket's own /bin) — the absence assertion below would be vacuous"; }
printf '%s\n' "$LS_BIN_BEFORE" | grep -q 'mcp-stub-runner' \
    && { printf '%s\n' "$LS_BIN_BEFORE" | head -8; \
         fail "BEFORE ARM: mcp-stub-runner IS in the live /bin listing of the pre-fix run — the publish-without-commit asymmetry is GONE (the pinned server committed?)"; }
# 3. the generation IS published in the store: disk CURRENT is the new version
read_from_disk "/store/.db/snapshots/CURRENT" "$WORK/b0-current.txt"
[ "$(tr -dc '0-9' < "$WORK/b0-current.txt")" = "$V_SLOT0" ] \
    || fail "before arm: disk CURRENT ($(cat "$WORK/b0-current.txt")) is not the published v$V_SLOT0 — the direct exec did not even publish"
# 4. NO re-arm: no second boot verdict on the console, and the OLD fxctl
#    transport (socket, ENOSYS in-guest) made fx_status dead — the pre-fix
#    state the --fifo rows fix.
grep -q "fx-init: boot-ok v$V_SLOT0" "$WORK/bootb.log" \
    && fail "before arm: boot-ok v$V_SLOT0 on the console — the direct-exec route re-armed the boot decision, which only the channel route does"
# ... the OLD fxctl transport (socket, ENOSYS in-guest) made fx_status dead
# — the pre-fix state the --fifo rows fix.  MEASURED reply shape: "fxctl:
# connect /run/fx/control.sock: Function not implemented" (connect(2) under
# a CONFIG_NET-less kernel).
grep -q 'control.sock: Function not implemented' "$WORK/b0-transcript.jsonl" \
    || { grep -o 'call_status.\{0,200\}' "$WORK/b0-transcript.jsonl" | head -3; \
         fail "before arm: fx_status did not fail with the socket-ENOSYS message — the pre-fix fxctl transport state is not what this arm pins"; }
RDINIT="$RDINIT_SAVED"
DISK="$WORK/disk.img"   # restore the LOOP disk: phase C boots it explicitly
echo "qemu-agent-slot-inguest: BEFORE arm GREEN (pinned $PIN_REV) — PUBLISHED (disk CURRENT v$V_SLOT0) but NOT COMMITTED (no /bin/mcp-stub-runner on the live root, no re-armed boot-ok, fx_status dead on the socket transport); the fixed server COMMITS (boot 1 above)"

# ═══ PHASE B1 — the refusal boot: PID1 REFUSES, the model SEES it ═══════
# A dedicated boot+store (the refused config PUBLISHES a generation — running
# this in the loop's boot would move disk CURRENT out from under boot 2).
# The agent writes the OVER-WIDE config (in the writable set for exactly this
# probe) and activates it THROUGH THE CHANNEL: fx-activate publishes it, PID1
# read_store_facts refuses to supervise it, and the reply must come back to
# the model as LOUD text with a NON-ZERO exit.
echo "=== qemu-agent-slot-inguest: phase B1 — the refusal boot (an over-wide config through the channel) ==="
RR="$WORK/root-refuse"
cp -a "$PAYROOT" "$RR" || fail "cannot copy the payload rootdir (refuse arm)"
mkdir -p "$RR/usr/fx-agent/cfg" || fail "cannot create the refuse arm's cfg dir"
cp "$R/usr/fx-agent/cfg/config.dhall" "$RR/usr/fx-agent/cfg/config.dhall" || fail "cannot copy the agent config"
mkfixture "$RR/usr/fx-agent/arm.sse" "$TEXT_MARKER" refuse
grep -q 'call_wide' "$RR/usr/fx-agent/arm.sse" || fail "the refuse fixture has no fx_activate probe"
STORER="$WORK/store-refuse"
provision "$STORER"
OUT_R=$(activate_host "$STORER" "$WORK/bracket.dhall") || fail "activate refuse-bracket failed: $OUT_R"
V_BR=$(echo "$OUT_R" | version_of); [ -n "$V_BR" ] || fail "cannot parse v_BR from: $OUT_R"
image "$RR" "$WORK/imgr.list" "$WORK/imgr.cpio.gz" "$STORER"
FXDR=$(ls -d "$STORER"/*-fx-init | head -1)
RDINIT_SAVED="$RDINIT"
RDINIT="/fx/store/$(basename "$FXDR")/fx-init"
DISKR="$WORK/disk-refuse.img"; new_disk "$DISKR"; fsck_once "$DISKR" r
disk_mkdirs "$DISKR" /agent-src /agent-src/oslot
# THE OVER-WIDE CONFIG, PRE-PLACED by the host (the guest mounts this disk at
# /fx/disk, so /agent-wide.dhall IS /fx/disk/agent-wide.dhall — the path the
# fixture's fx_activate names).  Read back once so the assertion below can
# never pass over a torn placement.
disk_put "$DISKR" "$WORK/wideconfig.dhall" /agent-wide.dhall
boot "$WORK/imgr.cpio.gz" "$WORK/bootr.log" "$DISKR"
cp "$WORK/bootr.log" "$EVID/boot-refuse-console.log"
# No boot-verdict assertion here, deliberately: the refused activation does
# NOT re-arm the window, and the (already-running) bracket window may expire
# over the FREED service table — naming whatever g_current_version held at
# that moment (a known fx-init quirk of the refusal path, out of this repo's
# scope).  What this arm proves is the machine came up, the agent ran, and
# the REFUSAL reached the model.
grep -q "fx-init: disk store mounted (current v$V_BR)" "$WORK/bootr.log" \
    || { tail -30 "$WORK/bootr.log"; halt; fail "refuse arm: the machine did not come up in the bracket v$V_BR"; }
grep -qF "$TEXT_MARKER" "$WORK/bootr.log" \
    || { tail -40 "$WORK/bootr.log"; halt; fail "refuse arm: the agent never ran"; }
halt
SIDR=$( "$DEBUGFS" -R "ls -p /agent-data/sessions" "$DISKR" 2>/dev/null \
        | sed -n 's|^/[0-9]*/[0-9]*/[0-9]*/[0-9]*/\([^/.][^/]*\)/*$|\1|p' | head -1 )
[ -n "$SIDR" ] || fail "refuse arm: no session on the disk"
read_from_disk "/agent-data/sessions/$SIDR/messages.jsonl" "$WORK/br-transcript.jsonl"
cp "$WORK/br-transcript.jsonl" "$EVID/boot-refuse-transcript.jsonl"
# THE REFUSAL, AS THE MODEL SEES IT: exit=1 + PID1's ERR line verbatim — the
# service-table overflow refusal naming the offender, the window, and the
# count of skipped rows.
grep -F 'exit=1\nERR activated version' "$WORK/br-transcript.jsonl" >/dev/null \
    || { grep -o 'call_wide.\{0,300\}' "$WORK/br-transcript.jsonl" | head -3; \
         fail "refuse arm: the reply is not PID1's refusal (exit=1 followed by its ERR line) — a refusal PID1 made did not reach the model as a loud failure"; }
grep -Eq 'but REFUSED: service .widesvc[0-9]+. is #65' "$WORK/br-transcript.jsonl" \
    || { grep -o 'call_wide.\{0,300\}' "$WORK/br-transcript.jsonl" | head -3; \
         fail "refuse arm: the refusal does not name the 65th service and the window"; }
grep -F ', window 64,' "$WORK/br-transcript.jsonl" >/dev/null \
    || { grep -o 'call_wide.\{0,300\}' "$WORK/br-transcript.jsonl" | head -3; \
         fail "refuse arm: the refusal does not state the window bound (PID1's verbatim ', window 64,' shape)"; }
# the refused generation IS published (the child committed before the
# refusal): disk CURRENT moved past the bracket — and the console carries
# read_store_facts' own loud refusal line.
read_from_disk "/store/.db/snapshots/CURRENT" "$WORK/br-current.txt"
V_WR=$(tr -dc '0-9' < "$WORK/br-current.txt")
[ -n "$V_WR" ] && [ "$V_WR" -gt "$V_BR" ] \
    || fail "refuse arm: disk CURRENT ($V_WR) did not move past the bracket v$V_BR — the wide config was never published"
grep -q 'refusing service table' "$WORK/bootr.log" \
    || { grep -n 'refus' "$WORK/bootr.log" | head -5; \
         fail "refuse arm: read_store_facts' loud refusal line is not on the console"; }
RDINIT="$RDINIT_SAVED"
DISK="$WORK/disk.img"   # restore the LOOP disk: phase C boots it explicitly
echo "qemu-agent-slot-inguest: REFUSE arm GREEN — PID1 published v$V_WR and REFUSED to supervise it; the model saw 'ERR ... is #65 ... window holds 64' with exit=1"

# ─── ARM 0%: the oracle AS-OF the bracket, over the guest-written store ──
disk_read_tree "$DISK" /store "$WORK/rb1-store"
[ -d "$WORK/rb1-store/.db" ] || fail "the disk store read-back has no .db"
run_oracle "$WORK/rb1-store" "$V_B" > "$WORK/out.before" \
    || fail "oracle refused the store as-of v$V_B: $(head -3 "$WORK/out.before")"
cp "$WORK/out.before" "$EVID/osier-share-before.txt"
B_FRAC=$(field "$WORK/out.before" run_set_share_fraction)
B_OS=$(field "$WORK/out.before" run_set_osier_bytes)
[ "$B_OS" = "0" ] && [ "$B_FRAC" = "0.000000" ] \
    || fail "ARM 0% FAILED: as-of the bracket the run set must read 0.000000 with a zero numerator (got frac=$B_FRAC osier=$B_OS) — see $WORK/out.before"
if grep -q '^component oslot ' "$WORK/out.before"; then
    fail "ARM 0% FAILED: an oslot component is attributed as-of the BRACKET, before the slot generation exists"
fi
echo "qemu-agent-slot-inguest: ARM 0% GREEN — run share $B_FRAC as-of the bracket v$V_B (the generation boot 1 ran)"

# ═══ PHASE C — boot 2: THE SAME IMAGE, THE SAME DISK, v_slot BOOTS ══════
echo "=== qemu-agent-slot-inguest: phase C — boot 2: same image (sha-compared), same disk, v$V_SLOT ==="
IMG_SHA2=$(sha256sum "$WORK/img1.cpio.gz" | awk '{print $1}')
[ "$IMG_SHA2" = "$IMG_SHA" ] \
    || fail "the initrd CHANGED between boots ($IMG_SHA -> $IMG_SHA2) — image surgery happened; the loop is not in-guest"
# (no e2fsck, no debugfs -w, no mkinitramfs between the boots: the only
# writer of this disk since boot 1 was the guest itself.)
boot "$WORK/img1.cpio.gz" "$WORK/boot2.log" "$DISK"
cp "$WORK/boot2.log" "$EVID/boot2-console.log"
grep -n 'disk store mounted\|boot-ok\|boot-FAILED\|oslot' "$WORK/boot2.log" | head -12
grep -q "fx-init: disk store mounted (current v$V_SLOT)" "$WORK/boot2.log" \
    || { tail -30 "$WORK/boot2.log"; halt; fail "boot 2: the disk's CURRENT is not the slot generation v$V_SLOT"; }
grep -q "fx-init: boot-ok v$V_SLOT" "$WORK/boot2.log" \
    || { tail -40 "$WORK/boot2.log"; halt; fail "boot 2: want boot-ok v$V_SLOT — the slot generation did not boot healthy"; }
halt
# THE SERVICE RAN — its durable marker on the disk the guest booted from.
read_from_disk "/oslot-stub-ran" "$WORK/b2-marker.txt"
[ -s "$WORK/b2-marker.txt" ] \
    || fail "boot 2: the stub runner never EXECUTED (no /oslot-stub-ran marker on the disk)"
grep -q 'oslot-stub-ran' "$WORK/b2-marker.txt" \
    || fail "boot 2: the marker file does not carry the runner's own line"
echo "qemu-agent-slot-inguest: boot 2 GREEN — v$V_SLOT booted off the same image+disk; the slot's service RAN (marker on the disk)"

# ─── ARM NON-ZERO + THE STORE'S OWN FACTS ────────────────────────────────
rm -rf "$WORK/rb2-store"
disk_read_tree "$DISK" /store "$WORK/rb2-store"
run_oracle "$WORK/rb2-store" > "$WORK/out.after" \
    || fail "oracle refused the boot-2 store: $(head -3 "$WORK/out.after")"
cp "$WORK/out.after" "$EVID/osier-share-after.txt"
A_FRAC=$(field "$WORK/out.after" run_set_share_fraction)
A_OS=$(field "$WORK/out.after" run_set_osier_bytes)
A_TOT=$(field "$WORK/out.after" run_set_total_bytes)
[ "$A_OS" = "$ELM_BYTES" ] \
    || fail "ARM NON-ZERO: the numerator ($A_OS) is not the agent's .elm bytes ($ELM_BYTES)"
awk -v t="$A_TOT" -v e="$ELM_BYTES" 'BEGIN { exit !(t >= e) }' \
    || fail "ARM NON-ZERO: denominator ($A_TOT) smaller than the numerator"
awk -v f="$A_FRAC" 'BEGIN { exit !(f > 0) }' \
    || fail "ARM NON-ZERO FAILED: the run share is still 0 ($A_FRAC) with the slot's service RUNNING"
[ "$A_FRAC" != "$B_FRAC" ] \
    || fail "THE ASYMMETRY FAILED: the share did not move ($B_FRAC -> $A_FRAC)"
grep -q "^component oslot $SLOT_SRC_HASH store $ELM_BYTES [0-9]* 1 1 run src_of$" "$WORK/out.after" \
    || { grep '^component ' "$WORK/out.after"; \
         fail "ARM NON-ZERO: oslot is not attributed BY THE STORE (want: component oslot $SLOT_SRC_HASH store ... run src_of)"; }
grep -q "^service oslot-mcp [0-9a-f]\\{64\\}-oslot/mcp-stub-runner oslot$" "$WORK/out.after" \
    || { grep '^service ' "$WORK/out.after"; fail "ARM NON-ZERO: the oslot-mcp service row is not attributed to the oslot package"; }
echo "qemu-agent-slot-inguest: ARM NON-ZERO GREEN — run share $B_FRAC (as-of v$V_B) -> $A_FRAC (v$V_SLOT); osier $A_OS/$A_TOT bytes; attribution src_of; origin store"

# THE STORE'S OWN FACTS (steering #2): shown off the disk the machine is
# running from — the host fxstore reads them, it does not write them.
for rel in store srcstore src_of; do
    ( cd "$WORK" && "$FXSTORE" facts "$rel" --store "$WORK/rb2-store" --as-of "$V_SLOT" ) \
        > "$EVID/facts-$rel.txt" 2>&1 \
        || { cat "$EVID/facts-$rel.txt"; fail "fxstore facts $rel failed on the read-back store"; }
done
grep -q "oslot" "$EVID/facts-store.txt" \
    || { cat "$EVID/facts-store.txt"; fail "facts store carries no oslot row"; }
grep -q "$SLOT_SRC_HASH" "$EVID/facts-src_of.txt" \
    || { cat "$EVID/facts-src_of.txt"; fail "facts src_of carries no row for the slot's src hash $SLOT_SRC_HASH"; }
grep -q "oslot" "$EVID/facts-srcstore.txt" \
    || { cat "$EVID/facts-srcstore.txt"; fail "facts srcstore carries no oslot row"; }
echo "qemu-agent-slot-inguest: store facts GREEN — store/srcstore/src_of rows for oslot on the disk (see $EVID/facts-*.txt)"

echo "=== qemu-agent-slot-inguest: PASS — the loop is IN THE GUEST: written, built (no host step), activated, run; one image, one disk; share $B_FRAC -> $A_FRAC ==="
exit 0
