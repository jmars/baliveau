#!/bin/sh
# tests/qemu-agent-slot.sh — THE SLOT PLUMBING, END TO END, IN A GUEST.
#
# WHAT THIS GATE IS FOR.  The first self-modification task (todo.md §5) is:
# the agent writes an MCP server in Osier, activates it as a service, and
# fx-osier-share moves 0% -> non-zero.  The Osier->Lua compiler does not
# exist yet, so THIS gate proves everything AROUND it, in a real guest, on
# a real store, with the compiler seat honestly filled by a STUB:
#
#   1. THE SLOT.  The deployment (not the agent) ships a package set
#      (fx-init/m3/package-set-slot.dhall) whose `oslot` package's src.path
#      is an in-guest directory, /fx/disk/agent-src/oslot.  The agent may
#      write EXACTLY ONE FILE there (FX_AGENT_WRITABLE names the file, not
#      the directory — the set is exact paths); the package set, the store,
#      and the harness record stay outside its reach, and the gate PROVES
#      all three refusals in-guest.
#   2. THE RECIPE IS HOST-FROZEN AND IS A STUB.  The oslot recipe installs
#      the agent's Mcp.elm beside a host-written busybox-sh stand-in runner
#      and a STUB-NOTE.  It is executed by the REAL `fxstore build` on the
#      host (the open todo decision "host-side or in-guest build": THIS
#      ground picks HOST-SIDE, like every other provisioned package in
#      these gates; the residual — the agent's source reaches the store
#      only through a host step — is stated in todo.md §5).  The built
#      artifact is INJECTED into the guest's own disk store between boots.
#      NOTHING here compiles, interprets or executes Osier, and the
#      artifact says so in its own bytes.
#   3. THE SERVICE RUNS.  The agent's activation puts `oslot` in the
#      generation's closure; the next boot starts the NON-console service
#      `oslot-mcp` whose svc_bin resolves to <hash>-oslot/mcp-stub-runner
#      (a #!/usr/bin/busybox sh script: the pinned kernel has
#      CONFIG_BINFMT_SCRIPT=y
#      and CANNOT exec the i386 LuaJIT artifact — no IA32 emulation, so
#      "under in-guest LuaJIT" is a shape for a different kernel, stated,
#      not faked).  The runner stays alive through the boot grace window
#      (fx-init pins `failed` for ANY non-console exit during grace) and
#      writes a marker on the disk: the artifact EXECUTED, proven by its
#      durable side effect, not by a console line.
#   4. THE ASYMMETRY, on the guest's OWN store.  After boot 1 (the slot
#      not in the closure) the oracle reads run_set_share_fraction
#      0.000000 over the run set off the DISK store; after boot 3 (the
#      slot's generation running the service) it reads NON-ZERO with the
#      oslot component attributed BY THE STORE (src_of, origin `store`).
#      The store is read back per-file with debugfs (rdump cannot run
#      unprivileged) — the same primitive the existing gates use, walked.
#
# THE BOOT SEQUENCE (one disk, one store, two images):
#   boot 1  image A: the bracket (no slot).  The agent fixture writes the
#           Osier source + the slot config, and its tamper probes (record,
#           store) are REFUSED.  No fx_activate call => no attempt line =>
#           the next boot's verdict is RUN (outcome.h: "no activation
#           recorded, not done"), which is what lets the SAME task
#           activate later — the host build step happens in between.
#   host    e2fsck -fy the disk; read the agent's source back per-file;
#           `fxstore build oslot` into a read-back copy of the disk store
#           (bwrap hidden from fxstore's probe = its sanctioned LOUD
#           non-hermetic fallback, the prov_e2e.sh merged-usr pattern);
#           e2fsck + debugfs -w inject <hash>-oslot and <src>-oslot-src
#           into the disk store.
#   boot 2  image B: same writes (idempotent) + fx_activate of the slot
#           config -> generation v_slot on the DISK store (durable-only;
#           this boot still runs the bracket).
#   boot 3  image B: boots v_slot.  heartbeat + oslot-mcp run; the stub
#           runner marks the disk; the oracle reads NON-ZERO.
#
# WHY TWO IMAGES: the fixture replays byte-identically every boot, but the
# task must NOT activate before the host build step exists (an fx_activate
# of an unbuilt slot would fail loudly and the observation loop would then
# rightly refuse to repeat it — a wedged first task).  Swapping the image
# between boots is the HOST's decision, exactly at the host-step boundary.
#
# NO CONTROL CHANNEL: like the observation gate, every assertion is the
# console (fx-init verdicts, the agent's console service) or a disco
# read-back off the virtio disk.
#
# Env: QEMU_BOOT_TIMEOUT (default 120)  QEMU_KEEP=1  FX_INIT_REPO
#      FX_KERNEL_CACHE  FXSTORE_BIN  SLOT_SKIP_BOOT=1 (stage + images only)
set -u

fail() { echo "qemu-agent-slot: FAIL: $*" >&2; exit 1; }
skip() { echo "qemu-agent-slot: SKIP ($*)"; exit 77; }

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
command -v e2fsck >/dev/null 2>&1 || true
E2FSCK=""
for _p in e2fsck /sbin/e2fsck /usr/sbin/e2fsck; do
    if command -v "$_p" >/dev/null 2>&1; then E2FSCK="$_p"; break; fi
done
[ -n "${E2FSCK:-}" ] || skip "e2fsck not found (the between-boots disk step)"
MKE2FS=""
for _p in mke2fs /sbin/mke2fs /usr/sbin/mke2fs; do
    if command -v "$_p" >/dev/null 2>&1 || [ -x "$_p" ]; then MKE2FS="$_p"; break; fi
done
[ -n "$MKE2FS" ] || skip "mke2fs not found (e2fsprogs)"
DEBUGFS=""
for _p in debugfs /sbin/debugfs /usr/sbin/debugfs; do
    if command -v "$_p" >/dev/null 2>&1 || [ -x "$_p" ]; then DEBUGFS="$_p"; break; fi
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

FXSTORE="${FXSTORE_BIN:-$REPO/../fxstore/zig-out/bin/fxstore}"
[ -x "$FXSTORE" ] || skip "fxstore binary missing at $FXSTORE (build the sibling)"
"$FXSTORE" --help 2>&1 | grep -q 'fxstore facts' || skip "fxstore at $FXSTORE predates 'facts' (rebuild the sibling)"
FXSTORE_DIR="$(cd "$(dirname "$FXSTORE")" && pwd)"
STAGE3="${FXSTORE_STAGE3:-$FXSTORE_DIR/../../vendor/palisade/bin/stage3}"
[ -x "$STAGE3" ] || skip "palisade stage3 not executable: $STAGE3 (fxstore refuses every Shell recipe without it)"
OSIER="${OSIER_BIN:-$REPO/build/fx-osier-share}"
[ -x "$OSIER" ] || fail "no oracle binary at $OSIER (make test-osier-share builds it)"

# the pinned kernel cannot exec i386 (MEASURED, tests/qemu-agent-observe.sh)
# and CAN exec #! scripts — both halves asserted, not assumed.  The
# interpreter is /usr/bin/busybox (the PIVOTED root binds /lib64 and /usr
# only — /bin/sh does not exist where services run; MEASURED, pivot_binds).
KCONFIG_PRE="${FX_KERNEL_CACHE:-$INIT/.kernel-cache}/kernel/config"
if [ -r "$KCONFIG_PRE" ]; then
    grep -q '^CONFIG_BINFMT_SCRIPT=y' "$KCONFIG_PRE" \
        || fail "the pinned kernel has no BINFMT_SCRIPT — the stub runner (a #! script) could never exec; re-read this lane"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qemuslot.XXXXXX")" || fail mktemp
if [ "${QEMU_KEEP:-0}" = "1" ]; then
    trap 'echo "qemu-agent-slot: scratch kept at $WORK"' EXIT
else
    trap 'rm -rf "$WORK"' EXIT
fi
EVID="${QEMU_SLOT_EVIDENCE_DIR:-$REPO/tests/evidence/qemu-agent-slot}"
mkdir -p "$EVID" || fail "cannot create the evidence dir $EVID"
STORE="$WORK/store"
mkdir -p "$STORE" || fail "cannot create the store"

# ─── the pinned kernel (fx-init's own fetcher + pin) ─────────────────────
KCACHE="${FX_KERNEL_CACHE:-$INIT/.kernel-cache}"
KERNEL="$KCACHE/kernel/vmlinuz"
WANT_SHA=$(sed -n 's/^vmlinuz_sha256 //p' "$PIN")
[ -n "$WANT_SHA" ] || skip "kernel pin file malformed"
if [ -r "$KERNEL" ] && [ "$(sha256sum "$KERNEL" | awk '{print $1}')" = "$WANT_SHA" ]; then
    echo "qemu-agent-slot: pinned kernel verified in cache"
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
# (re-read the config from whichever cache won, for the BINFMT assert above)
KCONFIG="$KCACHE/kernel/config"
if [ -r "$KCONFIG" ]; then
    grep -q '^CONFIG_BINFMT_SCRIPT=y' "$KCONFIG" \
        || fail "the pinned kernel has no BINFMT_SCRIPT — the stub runner could never exec"
    grep -q '^CONFIG_IA32_EMULATION=y' "$KCONFIG" \
        && fail "the pinned kernel HAS IA32 emulation — the guest-ABI premise is void, re-read this lane"
fi

# ─── the guest payload + fx-init's guest binaries ────────────────────────
echo "=== qemu-agent-slot: staging the guest payload ==="
sh "$REPO/tools/stage-guest.sh" || fail "tools/stage-guest.sh failed"
PAYLOAD="$REPO/build/guest-payload"
PAYROOT="$PAYLOAD/root"
PL_BIN="$PAYROOT/usr/fx-agent/bin"
for b in fx-agent fx-verbs-server; do
    [ -x "$PL_BIN/$b" ] || fail "payload has no $b"
done

assert_guest_elf() { # assert_guest_elf FILE ARCHDESC
    _f=$1 _d=$2
    [ -f "$_f" ] || fail "$_f missing"
    _t=$(file -b "$_f" 2>/dev/null)
    case "$_t" in *"statically linked"*) ;; *) fail "$_f is not static: $_t" ;; esac
    case "$_t" in *"stripped"*) ;; *) fail "$_f is not stripped: $_t" ;; esac
    case "$_t" in *"$_d"*) ;; *) fail "$_f is not $_d: $_t" ;; esac
}

ZB="$PAYLOAD/init-x86_64-musl/bin"
if [ ! -x "$ZB/fx-init" ] || [ "${QEMU_AGENT_REBUILD_INIT:-0}" = 1 ]; then
    echo "=== qemu-agent-slot: building fx-init's guest binaries (x86_64-linux-musl) ==="
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
echo "=== qemu-agent-slot: freezing package sources ($INIT + its siblings) ==="
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
# THE SLOT SET, path-rewritten to the frozen trees.  The oslot entry's
# GUEST path (/fx/disk/agent-src/oslot) stays verbatim: absolute src paths
# pass mkinitramfs -p untouched, and the derivation hash covers the source
# CONTENT hash, never the path — so the image's set and the host build's
# set (oslot re-pointed below, at build time) name the same package.
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

# ─── the agent's Osier source + the two configs ──────────────────────────
# THE AGENT-AUTHORED SOURCE: deterministic, obviously-Osier, and the ONLY
# thing the agent writes into the slot.  Its byte count is MEASURED below
# and asserted against the oracle's numerator.
OSIER_SRC="$WORK/Mcp.elm"
cat > "$OSIER_SRC" <<'ELM'
module Mcp exposing (tools, handle)
{- The agent-authored MCP server (Osier source).  This file is the ONLY
   thing the task writes: the deployment pre-declares the slot, the host
   freezes the recipe, and the store turns these bytes into the component
   the generation runs. -}
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
, { name = "slotagent", argv = [ "/usr/fx-agent/bin/fx-agent", "-p", "write your osier mcp server source and activate the slot",
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
# THE SLOT SERVICE: NON-console by design (a boot failure is what the
# recovery machinery handles; the console pin belongs to the agent row
# only), RUN via svc_bin -> <hash>-oslot/mcp-stub-runner (the package's
# build.target basename — that is how fx-activate resolves a pkg'd row).
oslot_svc() {
    cat <<DHALL
, { name = "oslot-mcp", argv = [ "mcp-stub-runner" ], pkg = Some "oslot",
            on = "all", restart = Some "always", backoffMs = Some 500,
            probe = None Probe,
            env = None (List { key : Text, value : Text }),
            console = None Text }
DHALL
}

# THE BRACKET: the healthy generation boots 1..2 run; the slot is NOT in
# its closure (that absence is the 0% arm).
{
    svc_head
    cat <<DHALL
in  { hostname = "slotbox"
    , packages = [ $BASE_PKGS ]
    , users = [ { name = "root", uid = 0, groups = [] : List Text } ]
    , services =
        [ $(heartbeat)
        $(agent_svc /usr/fx-agent/arm.sse)
        ]
    , extraEtc = None (List { path : Text, content : Text })
    , bootGraceMs = Some 30000
    , agentService = Some "slotagent"
    }
DHALL
} > "$WORK/bracket.dhall" || fail "cannot write the bracket config"

# THE SLOT CONFIG (what the agent writes to disk and activates): the slot
# IS in the closure, the agent service is NOT (nothing re-dispatches the
# fixture once this generation boots).
{
    svc_head
    cat <<DHALL
in  { hostname = "slotbox2"
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

# ─── the agent pin (substrate-owned; this file's own copy) ────────────────
# Same reasoning as tests/qemu-agent-observe.sh (this file's own copy; the
# observe gate's helpers are another lane's): a refusal exits 0, and fx-init
# pins `failed` for a NON-console service that exits during grace — an
# agent row that is not console would turn every refusal into a roll-forward
# oscillator.  The rule the old TEXT search approximated now lives in the
# SUBSTRATE: fx-init's config parser REQUIRES an agentService field and
# refuses a declared agent that is not a console service, at
# config-check/activation, before any boot.  The pin asserts the DECLARATION
# through the real parser binary and proves it can FAIL, by demanding the
# substrate REFUSE (a) the same config with the declaration OMITTED and
# (b) the same config with the agent row turned NON-console, naming the
# service.  A stale config_check (one that still accepts either mutant)
# fails the pin loudly — that is intentional.
agent_pin() { # agent_pin CFG NAME — CFG must declare NAME as its agent ('-' = None)
    _pc="${FX_INIT_CONFIG_CHECK:-$INIT/zig/zig-out/bin/config_check}"
    [ -x "$_pc" ] || fail "agent pin: $_pc missing — build fx-init's zig port (the pin runs the real parser, it does not approximate one)"
    _cfg="$1"; _want="$2"
    _out=$("$_pc" "$_cfg" 2>&1) || { printf '%s\n' "$_out" >&2; fail "agent pin: the substrate refused the payload config $_cfg"; }
    printf '%s\n' "$_out" | grep -q "^agent_service=$_want\$" \
        || fail "agent pin: $_cfg does not declare agent_service=$_want (dump says: $(printf '%s\n' "$_out" | sed -n 's/^agent_service=//p' | head -1))"
    # FIREABILITY (a): the declaration OMITTED must be refused, not defaulted.
    grep -v 'agentService' "$_cfg" > "$WORK/agent-pin-omit.dhall"
    cmp -s "$WORK/agent-pin-omit.dhall" "$_cfg" \
        && fail "agent pin: $_cfg carries no agentService line — the omission mutant could not be built"
    _oout=$("$_pc" "$WORK/agent-pin-omit.dhall" 2>&1) \
        && fail "agent pin: the substrate ACCEPTED $_cfg with agentService OMITTED — the required-field bound is gone (stale config_check?)"
    printf '%s\n' "$_oout" | grep -q "config missing 'agentService'" \
        || fail "agent pin: the omission refusal does not say the field is missing: $_oout"
    # FIREABILITY (b): a NAMED agent turned NON-console must be refused, named.
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
# EVERY payload config DECLARES its agent (the bracket names slotagent; the
# slot config the agent writes declares None — its agent-free shape is the
# point of the 0% arm, and it must be DECLARED, not defaulted).
agent_pin "$WORK/bracket.dhall" "slotagent"
agent_pin "$WORK/slotconfig.dhall" "-"

CCHK="$INIT/zig/zig-out/bin/config_check"
if [ -x "$CCHK" ]; then
    for c in "$WORK/bracket.dhall" "$WORK/slotconfig.dhall"; do
        out=$("$CCHK" "$c" 2>&1) || { echo "$out" >&2; fail "config_check rejected $c"; }
    done
else
    echo "qemu-agent-slot: WARNING: $CCHK absent — the configs were not parser-checked" >&2
fi

# ─── the payload roots + the recorded fixtures ───────────────────────────
# FX_AGENT_WRITABLE — THE EXPLICIT, NAMED WRITE SURFACE FOR THIS TASK:
# exactly TWO paths (the slot's source file + the task config on the
# disk), colon-separated EXACT paths.  The harness record, the store, the
# bootlog and CURRENT are in NO set, and the gate proves the refusals.
WRITABLE="$SLOT_SRC_FILE:$AGENT_CONFIG"
for variant in a b; do
    R="$WORK/root-$variant"
    cp -a "$PAYROOT" "$R" || fail "cannot copy the payload rootdir ($variant)"
    mkdir -p "$R/usr/fx-agent/cfg" || fail "cannot create the agent config dir ($variant)"
    cat > "$R/usr/fx-agent/cfg/config.dhall" <<DHALL
{ agents =
  [ { name = "fx"
    , agent_type = "agent"
    , mcp_servers =
      [ { command = "/usr/fx-agent/bin/fx-verbs-server"
        , args = [] : List Text
        , env = Some { FX_AGENT_WRITABLE = "$WRITABLE" }
        }
      ]
    }
  ]
}
DHALL
    [ -s "$R/usr/fx-agent/cfg/config.dhall" ] || fail "cannot write the agent config ($variant)"
done

# THE FIXTURES (the model, canned): image A writes and probes but does NOT
# activate; image B additionally ACTIVATES the slot config.  The 4th/5th
# calls are the write-bound probes: the harness's own RECORD and the STORE
# itself — both must be REFUSED inside the guest, naming the host-declared
# set, while the two declared writes succeed.
mkfixture() { # mkfixture OUT TEXT ELMFILE CFGFILE WITH_ACTIVATE
    python3 - "$@" <<'PYEOF'
import json, sys
out, text, elm, cfg, with_act = sys.argv[1:6]
elm_c, cfg_c = open(elm).read(), open(cfg).read()
def ev(name, obj):
    return "event: %s\ndata: %s\n\n" % (name, json.dumps(obj))
FORGED = "1799999999 0000000000000000 done - - 0 -\nFORGED-RECORD-PROBE"
calls = [
    ("call_outcome", "fx_outcome", {}),
    ("call_w_elm",   "fx_write",   {"path": sys.argv[6] if len(sys.argv) > 6 else "",
                                     "content": elm_c}),
    ("call_w_cfg",   "fx_write",   {"path": sys.argv[7] if len(sys.argv) > 7 else "",
                                     "content": cfg_c}),
]
if with_act == "1":
    calls.append(("call_activate", "fx_activate", {"config": sys.argv[8] if len(sys.argv) > 8 else ""}))
calls += [
    ("call_tamper_record", "fx_write", {"path": "/fx/disk/agent-data/attempts.jsonl",
                                        "content": FORGED}),
    ("call_tamper_store",  "fx_write", {"path": "/fx/disk/store/.bootlog",
                                        "content": "1 ok 0\nFORGED-STORE-PROBE\n"}),
]
s = [ev("response.created", {"type": "response.created",
                             "response": {"id": "slot-fixture", "status": "in_progress"}})]
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
             "response": {"id": "slot-fixture", "status": "completed"}}))
open(out, "w").write("".join(s))
PYEOF
}
TEXT_MARKER="SLOT-AGENT-RAN-$MARKER"
mkfixture "$WORK/root-a/usr/fx-agent/arm.sse" "$TEXT_MARKER" \
    "$OSIER_SRC" "$WORK/slotconfig.dhall" 0 \
    "$SLOT_SRC_FILE" "$AGENT_CONFIG" "$AGENT_CONFIG"
mkfixture "$WORK/root-b/usr/fx-agent/arm.sse" "$TEXT_MARKER" \
    "$OSIER_SRC" "$WORK/slotconfig.dhall" 1 \
    "$SLOT_SRC_FILE" "$AGENT_CONFIG" "$AGENT_CONFIG"
for v in a b; do
    grep -q 'fx_write' "$WORK/root-$v/usr/fx-agent/arm.sse" || fail "the fixture ($v) has no fx_write"
    grep -q 'FORGED-STORE-PROBE' "$WORK/root-$v/usr/fx-agent/arm.sse" || fail "the fixture ($v) has no store-tamper probe"
done
grep -q 'fx_activate' "$WORK/root-b/usr/fx-agent/arm.sse" || fail "fixture B has no fx_activate"
if grep -q 'fx_activate' "$WORK/root-a/usr/fx-agent/arm.sse"; then
    fail "fixture A MUST NOT activate (the host build step happens between boots 1 and 2)"
fi

# ─── provisioning (toolchain-free; the observe gate's shape) ─────────────
echo "=== qemu-agent-slot: provisioning the store (toolchain-free) ==="
export FX_SIBLINGS="${FX_SIBLINGS:-$SIBS}"
cp "$SIBS/dhake/dhake.com" "$WORK/dhake.com"; chmod +x "$WORK/dhake.com"
"$WORK/dhake.com" --assimilate || fail "dhake --assimilate failed"
file "$WORK/dhake.com" 2>/dev/null | grep -q 'statically linked' || skip "dhake.com did not assimilate to a static ELF"
( cd "$INIT" && zig cc -target x86_64-linux-musl -std=gnu11 -O2 -static \
    -o "$WORK/fakesvc" tests/fixtures/fakesvc/fakesvc.c ) || fail "zig cc fakesvc failed"
assert_guest_elf "$WORK/fakesvc" "x86-64"

PATHS=$(LD_LIBRARY_PATH="$DL" "$ZB/activate_paths" \
    --store "$STORE" --package-set "$PKGSET" \
    dhake fx-init fxctl fx-activate fake-service) || fail "activate_paths failed"
[ -n "$PATHS" ] || fail "activate_paths printed no closure"
echo "$PATHS" | while IFS= read -r pd; do
    mkdir -p "$STORE/$pd" || exit 1
    case "$pd" in
        *-fx-init)      cp "$ZB/fx-init"     "$STORE/$pd/fx-init";     chmod 755 "$STORE/$pd/fx-init" ;;
        *-fxctl)        cp "$ZB/fxctl"       "$STORE/$pd/fxctl";       chmod 755 "$STORE/$pd/fxctl" ;;
        *-fx-activate)  cp "$ZB/fx-activate" "$STORE/$pd/fx-activate"; chmod 755 "$STORE/$pd/fx-activate" ;;
        *-fake-service) cp "$WORK/fakesvc"   "$STORE/$pd/fakesvc";     chmod 755 "$STORE/$pd/fakesvc" ;;
        *-dhake)        cp "$WORK/dhake.com" "$STORE/$pd/dhake.com";   chmod 755 "$STORE/$pd/dhake.com" ;;
        *)              : > "$STORE/$pd/.provisioned-by-qemu-agent-slot" ;;
    esac
done

# ─── ONE activation of the BRACKET, then the two images ──────────────────
activate_host() { # activate_host CFG -> "activated <hash> as version N"
    LD_LIBRARY_PATH="$DL" "$ZB/fx-activate" --store "$STORE" \
        --package-set "$PKGSET" --config "$1" 2>&1
}
version_of() { sed -n 's/.*as version \([0-9][0-9]*\).*/\1/p' | head -1; }
image() { # image ROOTDIR LISTFILE OUT
    sh "$INIT/tests/mkinitramfs.sh" -s "$STORE" -r "$1" -k "$KERNEL" -o "$3" -l "$2" -p "$PKGSET" \
        || fail "mkinitramfs failed ($3)"
}

echo "=== qemu-agent-slot: activating the BRACKET (the healthy, slot-less generation) ==="
OUT_B=$(activate_host "$WORK/bracket.dhall") || fail "activate bracket failed: $OUT_B"
V_B=$(echo "$OUT_B" | version_of); [ -n "$V_B" ] || fail "cannot parse v_B from: $OUT_B"
echo "$OUT_B"
image "$WORK/root-a" "$WORK/img-a.list" "$WORK/img-a.cpio.gz"
image "$WORK/root-b" "$WORK/img-b.list" "$WORK/img-b.cpio.gz"
for want in usr/fx-agent/bin/fx-agent usr/fx-agent/bin/fx-verbs-server \
            usr/fx-agent/cfg/config.dhall usr/fx-agent/arm.sse; do
    grep -qx "$want" "$WORK/img-a.list" || fail "image A does not carry $want"
    grep -qx "$want" "$WORK/img-b.list" || fail "image B does not carry $want"
done
grep -qx "usr/fx/package-set.dhall" "$WORK/img-a.list" \
    || fail "the image does not carry the frozen package set (mkinitramfs -p)"
echo "qemu-agent-slot: both images carry the payload; bracket generation v$V_B"

FXD=$(ls -d "$STORE"/*-fx-init | head -1)
RDINIT="/fx/store/$(basename "$FXD")/fx-init"

# ─── disk helpers (debugfs; rdump cannot run unprivileged — walk per file)
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
new_disk() {
    qemu-img create -q "$1" 512M || fail "qemu-img create ($1) failed"
    "$MKE2FS" -q -t ext4 -J size=4 "$1" >/dev/null 2>&1 || fail "mke2fs ($1) failed"
}
read_from_disk() { "$DEBUGFS" -R "dump $1 $2" "$DISK" >/dev/null 2>&1 </dev/null; }
# e2fsck exit codes 0/1/2 are success-shaped (0 clean, 1 errors CORRECTED,
# 2 reboot-needed); 4+ means uncorrectable — the disk is not safe to write.
fsck_disk() {
    "$E2FSCK" -fy "$DISK" >"$WORK/e2fsck.log" 2>&1
    _rc=$?
    [ "$_rc" -le 3 ] || { tail -8 "$WORK/e2fsck.log" >&2; fail "e2fsck -fy failed (rc=$_rc) on the disk — cannot safely write into it"; }
    return 0
}
# THE PRE-DECLARED SEAT: fx_write cannot mkdir parents, so the slot's src
# DIRECTORY is created by the deployment (the host), on the disk, before
# the agent ever runs.  The agent writes the FILE; the host names the DIR.
disk_mkdirs() { # disk_mkdirs DIR...
    : > "$WORK/dbg-cmds"
    for d in "$@"; do echo "mkdir $d" >> "$WORK/dbg-cmds"; done
    "$DEBUGFS" -w -f "$WORK/dbg-cmds" "$DISK" >/dev/null 2>&1 \
        || fail "debugfs mkdir failed (the slot seat)"
    for d in "$@"; do
        "$DEBUGFS" -R "ls -l $d" "$DISK" >/dev/null 2>&1 || fail "debugfs cannot see $d after mkdir"
    done
}
# read a whole directory TREE off the disk, per file (rdump chowns => EPERM).
# EVERY debugfs child gets < /dev/null: the recursion runs inside a
# while-read loop, and a debugfs that inherits the loop's stdin CONSUMES the
# remaining listing lines — the walk silently stops after one entry (the
# reader was right; the ITERATION was broken — MEASURED on this gate).
disk_read_tree() { # disk_read_tree INPATH OUTDIR
    _in=$1 _out=$2
    mkdir -p "$_out"
    disk_read_tree_rec() {
        # NO `local` in POSIX sh: _p/_o/_listing are GLOBALS, saved+restored
        # around the recursive call — without that, the recursion clobbers
        # the caller's _p and every sibling is walked as a CHILD of the
        # previous one (paths nest: /store/a/b/c/... — MEASURED on this gate)
        _p=$1 _o=$2
        mkdir -p "$_o"
        _listing=$("$DEBUGFS" -R "ls -l $_p" "$DISK" 2>/dev/null </dev/null) || return 0
        printf '%s\n' "$_listing" | while IFS= read -r _ln; do
            # debugfs ls -l: ino mode links uid gid size date time name...
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
                *)  "$DEBUGFS" -R "dump $_child $_o/$_name" "$DISK" >/dev/null 2>&1 </dev/null || : ;;
            esac
        done
    }
    disk_read_tree_rec "$_in" "$_out" </dev/null
}
# write a FILE into the disk image (creating parent dirs); MODE is the
# decimal+octal inode mode debugfs `sif` expects (0100755 / 0100644)
disk_write_file() { # disk_write_file LOCALFILE ABSPATH MODE
    _lf=$1 _ap=$2 _mode=$3
    _dir=$(dirname "$_ap")
    : > "$WORK/dbg-cmds"
    _acc=""
    OLDIFS=$IFS; IFS=/
    for _seg in $_dir; do
        [ -n "$_seg" ] || continue
        _acc="$_acc/$_seg"
        echo "mkdir $_acc" >> "$WORK/dbg-cmds"
    done
    IFS=$OLDIFS
    { echo "cd $_dir"
      echo "write $_lf $(basename "$_ap")"
      echo "sif $(basename "$_ap") mode $_mode"
    } >> "$WORK/dbg-cmds"
    "$DEBUGFS" -w -f "$WORK/dbg-cmds" "$DISK" >"$WORK/dbg-write.log" 2>&1 \
        || { cat "$WORK/dbg-write.log" >&2; fail "debugfs write failed for $_ap"; }
    if grep -qi 'not found\|error' "$WORK/dbg-write.log" 2>/dev/null; then
        sed 's/^/    /' "$WORK/dbg-write.log" >&2
        fail "debugfs reported an error writing $_ap"
    fi
}

run_oracle() { # run_oracle STOREDIR -> oracle stdout
    FXSTORE_BIN="$FXSTORE" "$OSIER" --store "$1" --package-set "$PKGSET"
}
field() { sed -n "s/^$2 //p" "$1" | head -1; }

# ═══ BOOT 1 — image A: the agent writes; the slot is NOT in the closure ═══
DISK="$WORK/disk.img"; new_disk "$DISK"
fsck_disk
disk_mkdirs /agent-src /agent-src/oslot
echo "=== qemu-agent-slot: boot 1 — bracket v$V_B; the agent writes the slot source (no activation yet) ==="
boot "$WORK/img-a.cpio.gz" "$WORK/boot1.log"
cp "$WORK/boot1.log" "$EVID/boot1-console.log"
grep -n 'disk store mounted\|boot-ok\|boot-FAILED\|SLOT-AGENT-RAN' "$WORK/boot1.log" | head -10
grep -q "fx-init: boot-ok v$V_B" "$WORK/boot1.log" \
    || { tail -30 "$WORK/boot1.log"; halt; fail "boot 1: want boot-ok v$V_B"; }
grep -qF "$TEXT_MARKER" "$WORK/boot1.log" \
    || { tail -40 "$WORK/boot1.log"; halt; fail "boot 1: the agent never ran (no '$TEXT_MARKER')"; }
halt

# RAW STATE, PRE-FSCK (debugfs reads raw metadata; this is the platter, not
# any cached view): if the seeding's .db copy is missing HERE, the guest
# never wrote it out before the kill — a fact the gate must SEE, not paper
# over.
"$DEBUGFS" -R 'ls -l /store' "$DISK" > "$EVID/boot1-store-raw.listing" 2>/dev/null || :
grep -q '\.db' "$EVID/boot1-store-raw.listing" \
    || { sed 's/^/    /' "$EVID/boot1-store-raw.listing"; \
         fail "boot 1: the disk store has NO .db even before e2fsck — the guest's seeding copy never reached the platter (abrupt kill loses it); the read-back would be a fixture, not the guest's store"; }

# THE WRITE SURFACE, IN THE GUEST: both declared writes land; the record
# and the store are refused, naming the host-declared set.
read_from_disk "/agent-src/oslot/Mcp.elm" "$WORK/b1-elm.txt"
cmp -s "$WORK/b1-elm.txt" "$OSIER_SRC" \
    || { diff "$OSIER_SRC" "$WORK/b1-elm.txt" | head -10; fail "boot 1: the agent's Osier source is not byte-identical on the disk"; }
read_from_disk "/agent-config.dhall" "$WORK/b1-cfg.txt"
cmp -s "$WORK/b1-cfg.txt" "$WORK/slotconfig.dhall" \
    || fail "boot 1: the slot config is not byte-identical on the disk"
read_from_disk "/agent-data/attempts.jsonl" "$WORK/b1-record.txt"
[ -s "$WORK/b1-record.txt" ] || fail "boot 1: no durable record on the disk"
grep -q " attempt " "$WORK/b1-record.txt" \
    && { cat "$WORK/b1-record.txt"; fail "boot 1: an ACTIVATION was recorded — fixture A must not activate (the host build step has not run yet)"; }
grep -q "FORGED-RECORD-PROBE" "$WORK/b1-record.txt" \
    && { cat "$WORK/b1-record.txt"; fail "boot 1: forged content REACHED the record"; }
grep -q "FORGED-STORE-PROBE" "$WORK/b1-record.txt" \
    && fail "boot 1: forged content reached the record via the store probe"
SID=$( "$DEBUGFS" -R "ls -p /agent-data/sessions" "$DISK" 2>/dev/null \
       | sed -n 's|^/[0-9]*/[0-9]*/[0-9]*/[0-9]*/\([^/.][^/]*\)/*$|\1|p' | head -1 )
[ -n "$SID" ] || fail "boot 1: no session on the disk"
read_from_disk "/agent-data/sessions/$SID/messages.jsonl" "$WORK/b1-transcript.jsonl"
cp "$WORK/b1-transcript.jsonl" "$EVID/boot1-transcript.jsonl"
grep -q "bytes to $SLOT_SRC_FILE" "$WORK/b1-transcript.jsonl" \
    || { grep -o 'wrote [0-9]* bytes.\{0,60\}' "$WORK/b1-transcript.jsonl" | head -4; \
         fail "boot 1: the agent's SOURCE write was refused — the writable set broke the task's one legitimate source write"; }
grep -q "bytes to $AGENT_CONFIG" "$WORK/b1-transcript.jsonl" \
    || fail "boot 1: the agent's CONFIG write was refused"
grep -q 'fx_write REFUSED' "$WORK/b1-transcript.jsonl" \
    || { grep -o 'fx_write.\{0,90\}' "$WORK/b1-transcript.jsonl" | head -4; \
         fail "boot 1: no in-guest fx_write refusal — the write-bound probes never fired"; }
grep -q 'FX_AGENT_WRITABLE' "$WORK/b1-transcript.jsonl" \
    || fail "boot 1: the refusal does not name the host-declared set"
_nref=$(grep -c 'fx_write REFUSED' "$WORK/b1-transcript.jsonl" || true)
[ "$_nref" -ge 2 ] \
    || fail "boot 1: expected BOTH the record and the store tamper probes refused, got $_nref refusal(s)"
echo "qemu-agent-slot: boot 1 GREEN — source+config written in-guest; record and store writes REFUSED ($_nref)"

# ─── ARM 0%: the oracle over the RUN SET, on the guest's OWN store ───────
fsck_disk
disk_read_tree /store "$WORK/rb1-store"
[ -d "$WORK/rb1-store/.db" ] || fail "the disk store read-back has no .db"
run_oracle "$WORK/rb1-store" > "$WORK/out.before" \
    || fail "oracle refused the boot-1 store: $(head -3 "$WORK/out.before")"
cp "$WORK/out.before" "$EVID/osier-share-before.txt"
B_FRAC=$(field "$WORK/out.before" run_set_share_fraction)
B_OS=$(field "$WORK/out.before" run_set_osier_bytes)
B_TOT=$(field "$WORK/out.before" run_set_total_bytes)
[ "$B_OS" = "0" ] && [ "$B_FRAC" = "0.000000" ] \
    || fail "ARM 0% FAILED: before the slot the run set must read 0.000000 with a zero numerator (got frac=$B_FRAC osier=$B_OS total=$B_TOT) — see $WORK/out.before"
grep -qx "service slotagent /usr/fx-agent/bin/fx-agent NONSTORE-UNATTRIBUTED" "$WORK/out.before" \
    || { grep '^service ' "$WORK/out.before"; fail "ARM 0%: the agent service row is not reported NONSTORE-UNATTRIBUTED"; }
grep -q '^component fake-service ' "$WORK/out.before" \
    || fail "ARM 0%: the heartbeat's fake-service component is missing from the table"
if grep -q '^component oslot ' "$WORK/out.before"; then
    fail "ARM 0% FAILED: an oslot component is already attributed before the slot exists"
fi
echo "qemu-agent-slot: ARM 0% GREEN — run share $B_FRAC over the guest's own disk store (slot not in the closure)"

if [ "${SLOT_SKIP_BOOT:-0}" = "1" ]; then
    echo "qemu-agent-slot: SLOT_SKIP_BOOT=1 — staging complete (images + disk in $WORK), v_B=$V_B"
    echo "qemu-agent-slot: PASS (stage-only)"
    exit 0
fi

# ─── THE HOST BUILD STEP — the host-frozen STUB recipe, really executed ──
# fxstore build runs in a read-back COPY of the guest's own store, on the
# agent's own bytes read back off the disk; the resulting content-addressed
# dirs are injected back into the disk.  bwrap is hidden from fxstore's
# startup probe (merged-usr host: its sandbox cannot bind /bin) so it takes
# its own sanctioned LOUD non-hermetic fallback — prov_e2e.sh's pattern.
echo "=== qemu-agent-slot: HOST BUILD — fxstore build oslot (the STUB recipe) on the agent's read-back source ==="
read_from_disk "/agent-src/oslot/Mcp.elm" "$WORK/agent-src-Mcp.elm"
mkdir -p "$WORK/agent-src/oslot"
cp "$WORK/agent-src-Mcp.elm" "$WORK/agent-src/oslot/Mcp.elm"
cmp -s "$WORK/agent-src/oslot/Mcp.elm" "$OSIER_SRC" \
    || fail "the read-back source differs from the fixture bytes (the disk lies?)"
rm -rf "$WORK/gstore"
disk_read_tree /store "$WORK/gstore"
# the build copy of the package set: identical bytes EXCEPT the oslot src
# path, which names the host read-back tree (the derivation hash covers
# the source CONTENT hash, never the path — same package, same bytes)
mkdir -p "$WORK/build-ps"
sed "s|< Path = \"$SLOT_SRC_DIR\" >|< Path = \"$WORK/agent-src/oslot\" >|" \
    "$PKGSET" > "$WORK/build-ps/package-set.dhall"
grep -qF "< Path = \"$WORK/agent-src/oslot\" >" "$WORK/build-ps/package-set.dhall" \
    || fail "the build pkgset rewrite missed the oslot path"
mkdir -p "$WORK/hostpath"
for t in sh cp chmod mv rm cat mkdir ln dirname; do
    ln -sf "$(command -v "$t")" "$WORK/hostpath/$t" 2>/dev/null \
        || fail "the host build step needs '$t' on PATH"
done
( cd "$WORK/build-ps" && FXSTORE_STAGE3="$STAGE3" PATH="$WORK/hostpath" \
    "$FXSTORE" build --store "$WORK/gstore" oslot ) > "$WORK/hostbuild.log" 2>&1 \
    || { tail -12 "$WORK/hostbuild.log" >&2; fail "fxstore build oslot failed (the host-frozen stub recipe)"; }
cp "$WORK/hostbuild.log" "$EVID/hostbuild.log"
SLOT_DIR=$(ls -d "$WORK/gstore"/*-oslot 2>/dev/null | grep -v -- '-oslot-src' | head -1)
[ -n "$SLOT_DIR" ] || fail "the host build produced no <hash>-oslot dir"
SLOT_SRCART=$(ls -d "$WORK/gstore"/*-oslot-src 2>/dev/null | head -1)
[ -n "$SLOT_SRCART" ] || fail "the host build produced no <src_hash>-oslot-src clean-source artifact"
grep -q 'WARNING: bwrap not found' "$WORK/hostbuild.log" \
    && echo "qemu-agent-slot: NOTE — fxstore took its LOUD non-hermetic fallback (merged-usr host)"
cmp -s "$SLOT_DIR/Mcp.elm" "$OSIER_SRC" \
    || fail "the built package's Mcp.elm is not the agent's bytes"
head -1 "$SLOT_DIR/mcp-stub-runner" | grep -q '^#!/usr/bin/busybox sh$' \
    || fail "the built runner is not a #!/usr/bin/busybox sh script (it would die ENOENT in the pivoted root)"
grep -q 'STUB' "$SLOT_DIR/mcp-stub-runner" \
    || fail "the built runner does not say STUB in its own bytes"
[ -s "$SLOT_DIR/STUB-NOTE" ] || fail "the built package carries no STUB-NOTE"
grep -q 'NOT an Osier toolchain' "$SLOT_DIR/STUB-NOTE" \
    || fail "the STUB-NOTE does not say what it is not"
[ -x "$SLOT_DIR/mcp-stub-runner" ] || fail "the built runner is not executable"
echo "qemu-agent-slot: host build GREEN — $(basename "$SLOT_DIR") (stub runner + agent source + STUB-NOTE)"

# inject the two store dirs into the GUEST'S OWN disk store
echo "=== qemu-agent-slot: injecting the built slot into the disk store (e2fsck + debugfs -w) ==="
fsck_disk
disk_write_file "$SLOT_DIR/mcp-stub-runner" "/store/$(basename "$SLOT_DIR")/mcp-stub-runner" 0100755
disk_write_file "$SLOT_DIR/Mcp.elm"        "/store/$(basename "$SLOT_DIR")/Mcp.elm"         0100644
disk_write_file "$SLOT_DIR/STUB-NOTE"      "/store/$(basename "$SLOT_DIR")/STUB-NOTE"       0100644
disk_write_file "$SLOT_SRCART/Mcp.elm"     "/store/$(basename "$SLOT_SRCART")/Mcp.elm"      0100644
"$E2FSCK" -fn "$DISK" >"$WORK/fsck-after-inject.log" 2>&1 \
    || { tail -8 "$WORK/fsck-after-inject.log" >&2; fail "e2fsck -fn reports inconsistency after the injection"; }
read_from_disk "/store/$(basename "$SLOT_DIR")/mcp-stub-runner" "$WORK/inject-check.sh"
cmp -s "$WORK/inject-check.sh" "$SLOT_DIR/mcp-stub-runner" \
    || fail "the injected runner does not read back byte-identical (debugfs write broke it)"

# ═══ BOOT 2 — image B: the agent ACTIVATES the slot config ═══════════════
echo "=== qemu-agent-slot: boot 2 — the agent activates the slot config -> v_slot on the disk store ==="
boot "$WORK/img-b.cpio.gz" "$WORK/boot2.log"
cp "$WORK/boot2.log" "$EVID/boot2-console.log"
grep -n 'disk store mounted\|boot-ok\|boot-FAILED\|SLOT-AGENT-RAN\|activated' "$WORK/boot2.log" | head -10
# The boot STARTED in the bracket; its OWN verdict may never fire — under the
# channel route the agent activates inside the grace window and the re-armed
# window (asserted below, after the record is read: boot-ok v$V_SLOT) owns
# this console's verdict.
grep -q "fx-init: disk store mounted (current v$V_B)" "$WORK/boot2.log" \
    || { tail -30 "$WORK/boot2.log"; halt; fail "boot 2: the machine did not come up in the bracket v$V_B"; }
grep -qF "$TEXT_MARKER" "$WORK/boot2.log" \
    || { tail -40 "$WORK/boot2.log"; halt; fail "boot 2: the fixture never dispatched — the observation loop did not reach the RUN verdict after the write-only boot 1"; }
halt
read_from_disk "/agent-data/attempts.jsonl" "$WORK/b2-record.txt"
grep -q " attempt " "$WORK/b2-record.txt" \
    || { cat "$WORK/b2-record.txt"; fail "boot 2: no activation attempt on the record"; }
V_SLOT=$(sed -n 's/.* result .* \([0-9][0-9]*\).*/\1/p' "$WORK/b2-record.txt" | head -1)
[ -n "$V_SLOT" ] || { cat "$WORK/b2-record.txt"; fail "boot 2: no recorded activation RESULT on the disk"; }
[ "$V_SLOT" -gt "$V_B" ] || fail "boot 2: the slot generation v$V_SLOT is not above the bracket v$V_B"
# the transcript: every session on the disk, concatenated (the boot-2
# session is the newest, but ls order is not a promise)
: > "$WORK/b2-transcript.jsonl"
for _sess in $( "$DEBUGFS" -R "ls -p /agent-data/sessions" "$DISK" 2>/dev/null \
       | sed -n 's|^/[0-9]*/[0-9]*/[0-9]*/[0-9]*/\([^/.][^/]*\)/*$|\1|p' ); do
    read_from_disk "/agent-data/sessions/$_sess/messages.jsonl" "$WORK/b2-tmp.jsonl"
    cat "$WORK/b2-tmp.jsonl" >> "$WORK/b2-transcript.jsonl" 2>/dev/null || :
done
cp "$WORK/b2-transcript.jsonl" "$EVID/boot2-transcript.jsonl"
grep -q "activated version $V_SLOT" "$WORK/b2-transcript.jsonl" \
    || { grep -o 'fx_activate.\{0,120\}' "$WORK/b2-transcript.jsonl" | head -3; \
         fail "boot 2: the fx_activate reply does not report version $V_SLOT (PID1's channel reply 'activated version N')"; }
# THE CHANNEL ROUTE'S COMMIT, IN THE CROSS-MACHINE GATE TOO: the activation
# goes through PID1, so the re-armed window judges the NEW generation in the
# SAME boot — a SECOND verdict on boot 2's console.  (Pre-2026-10 the
# activation was durable-only: one verdict per console, the slot booted only
# on the NEXT boot.)
grep -q "fx-init: boot-ok v$V_SLOT" "$WORK/boot2.log" \
    || { grep -n 'boot-ok\|boot-FAILED' "$WORK/boot2.log" | head -5; halt; \
         fail "boot 2: no 'boot-ok v$V_SLOT' on the console — the channel activation did not COMMIT + RE-ARM in this boot"; }
grep -q "current $V_B" "$WORK/b2-transcript.jsonl" \
    || { grep -o 'current [0-9]*' "$WORK/b2-transcript.jsonl" | head -3; \
         fail "boot 2: the fx_outcome reply does not report the guest's real CURRENT (v$V_B)"; }
read_from_disk "/store/.db/snapshots/CURRENT" "$WORK/b2-current.txt"
[ "$(tr -dc '0-9' < "$WORK/b2-current.txt")" = "$V_SLOT" ] \
    || fail "boot 2: the disk store's CURRENT ($(cat "$WORK/b2-current.txt")) is not the slot generation v$V_SLOT"
grep -q "FORGED-RECORD-PROBE" "$WORK/b2-record.txt" \
    && fail "boot 2: forged content REACHED the record"
echo "qemu-agent-slot: boot 2 GREEN — fx_activate took in-guest: v$V_SLOT is CURRENT on the disk store"

# ═══ BOOT 3 — the slot generation BOOTS; the service RUNS ════════════════
echo "=== qemu-agent-slot: boot 3 — v$V_SLOT boots; oslot-mcp (non-console) must RUN ==="
boot "$WORK/img-b.cpio.gz" "$WORK/boot3.log"
cp "$WORK/boot3.log" "$EVID/boot3-console.log"
grep -n 'disk store mounted\|boot-ok\|boot-FAILED\|oslot' "$WORK/boot3.log" | head -12
grep -q "fx-init: disk store mounted (current v$V_SLOT)" "$WORK/boot3.log" \
    || { tail -30 "$WORK/boot3.log"; halt; fail "boot 3: the disk's CURRENT is not the slot generation v$V_SLOT"; }
grep -q "fx-init: boot-ok v$V_SLOT" "$WORK/boot3.log" \
    || { tail -40 "$WORK/boot3.log"; halt; fail "boot 3: want boot-ok v$V_SLOT — the slot generation did not boot healthy (svc_bin resolution? grace-window exit?)"; }
halt
# THE SERVICE RAN — proven by its durable side effect on the disk (its
# stdout goes to the log DB, not the console: it is a NON-console service).
read_from_disk "/oslot-stub-ran" "$WORK/b3-marker.txt"
[ -s "$WORK/b3-marker.txt" ] \
    || fail "boot 3: the stub runner never EXECUTED (no /oslot-stub-ran marker on the disk) — the service did not run the artifact"
grep -q 'oslot-stub-ran' "$WORK/b3-marker.txt" \
    || fail "boot 3: the marker file does not carry the runner's own line"
echo "qemu-agent-slot: boot 3 GREEN — the slot's service RAN (marker on the disk: $(wc -l < "$WORK/b3-marker.txt" | tr -d ' ') line(s))"

# ─── ARM NON-ZERO: the same machine, the same store, the oracle ──────────
fsck_disk
rm -rf "$WORK/rb3-store"
disk_read_tree /store "$WORK/rb3-store"
run_oracle "$WORK/rb3-store" > "$WORK/out.after" \
    || fail "oracle refused the boot-3 store: $(head -3 "$WORK/out.after")"
cp "$WORK/out.after" "$EVID/osier-share-after.txt"
A_FRAC=$(field "$WORK/out.after" run_set_share_fraction)
A_OS=$(field "$WORK/out.after" run_set_osier_bytes)
A_TOT=$(field "$WORK/out.after" run_set_total_bytes)
A_CL=$(field "$WORK/out.after" closure_share_fraction)
[ "$A_OS" = "$ELM_BYTES" ] \
    || fail "ARM NON-ZERO: the numerator ($A_OS) is not the agent's .elm bytes ($ELM_BYTES)"
awk -v t="$A_TOT" -v e="$ELM_BYTES" 'BEGIN { exit !(t >= e) }' \
    || fail "ARM NON-ZERO: denominator ($A_TOT) smaller than the numerator"
awk -v f="$A_FRAC" 'BEGIN { exit !(f > 0) }' \
    || fail "ARM NON-ZERO FAILED: the run share is still 0 ($A_FRAC) with the slot's service RUNNING"
[ "$A_FRAC" != "$B_FRAC" ] \
    || fail "THE ASYMMETRY FAILED: the share did not move ($B_FRAC -> $A_FRAC) — the oracle does not see the slot"
SLOT_HASH=$(printf '%s\n' "$SLOT_SRCART" | sed 's|.*/\([0-9a-f]\{64\}\)-oslot-src|\1|')
grep -q "^component oslot $SLOT_HASH store $ELM_BYTES [0-9]* 1 1 run src_of$" "$WORK/out.after" \
    || { grep '^component ' "$WORK/out.after"; \
         fail "ARM NON-ZERO: oslot is not attributed BY THE STORE (want: component oslot $SLOT_HASH store ... run src_of)"; }
grep -q '^attribution src_of ' "$WORK/out.after" \
    || fail "ARM NON-ZERO: no attribution summary line"
grep -q "^service oslot-mcp [0-9a-f]\\{64\\}-oslot/mcp-stub-runner oslot$" "$WORK/out.after" \
    || { grep '^service ' "$WORK/out.after"; fail "ARM NON-ZERO: the oslot-mcp service row is not attributed to the oslot package via its store-relative svc_bin"; }
if grep -q '^component oslot .* srcstore$' "$WORK/out.after"; then
    fail "ARM NON-ZERO: oslot was attributed by srcstore-narrowing, not by src_of — the store's own attribution row is missing (which activation wrote it?)"
fi
grep -q '^component fake-service ' "$WORK/out.after" \
    || fail "ARM NON-ZERO: the heartbeat left the component table"
echo "qemu-agent-slot: ARM NON-ZERO GREEN — run share $B_FRAC -> $A_FRAC; osier $A_OS/$A_TOT bytes; attribution src_of; origin store"
echo "qemu-agent-slot:   the store path that produced the component: <store>/$SLOT_HASH-oslot-src (clean-source artifact)"

echo "=== qemu-agent-slot: PASS — the slot plumbing is proven end-to-end in a guest, compiler absent, artifact labelled STUB ==="
exit 0
