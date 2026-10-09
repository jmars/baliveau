#!/bin/sh
# tools/stage-guest.sh — build the QEMU GUEST payload for tests/qemu-agent.sh.
#
# WHAT THIS PRODUCES (everything under build/guest-payload/ — this lane's own
# directory; nothing outside it is written):
#
#   root/                              a mkinitramfs.sh -r ROOTDIR tree
#     usr/fx-agent/bin/fx-agent          x86_64-linux-musl, static, stripped
#     usr/fx-agent/bin/fx-agent.i386     x86-linux-musl, static, stripped
#     usr/fx-agent/bin/fx-verbs-server   x86_64-linux-musl, static, stripped
#     usr/fx-agent/cfg/config.dhall      the harness's RUNTIME config (agents)
#     usr/fx-agent/chardev.sse           the canned SSE stream (offline arm)
#     usr/fx-agent/MARKER                the string that stream yields
#   fx-agent-service.dhall             the fx-init SERVICE config for the boot
#   marker.txt / sentinel.txt          read back by tests/qemu-agent.sh
#
# WHY /usr/fx-agent AND NOT mkinitramfs.sh -b BINDIR:
#   -b copies EVERY REGULAR FILE of BINDIR into /usr/fx-core/bin, the SAME
#   directory as the audited fx-* stage vocabulary (fxsh, fx-ls, fx-grep, ...).
#   An agent binary staged there is indistinguishable from a stage by any
#   reader of that directory.  The ROOTDIR overlay (-r) reaches the same
#   place — /usr is one of fx-init's pivot binds, so it is present PRE- AND
#   POST-PIVOT exactly like /usr/fx-core/bin — without colonizing the stage
#   vocabulary.  MEASURED equivalent: the payload is visible in the guest at
#   /usr/fx-agent/... both before and after pivot_root_to_tmpfs().
#
# GUEST ABI — THE LOAD-BEARING FACT (MEASURED, see tests/qemu-agent.sh):
#   The harness's Makefile guest target is x86-linux-musl (i386) — correct for
#   the v86 lane, whose guest CPU is 32-bit.  The QEMU lane's pinned kernel
#   (fx-init/scripts/kernel-pin.txt) has `# CONFIG_IA32_EMULATION is not set`,
#   so an EM_386 ELF cannot be exec'd there at all (binfmt_elf's
#   elf_check_arch rejects it: execve -> ENOEXEC).  This script therefore
#   stages BOTH ABIs under distinct names and tests/qemu-agent.sh uses the
#   i386 one as an ASYMMETRY CONTROL in the SAME boot: both binaries print a
#   signature line on the HOST (this host's kernel has IA32 emulation), only
#   the x86_64 one can print it in the GUEST.  No fx-init (or kernel) change
#   is needed to do that; the x86_64 artifact is built here from the SAME
#   sources the Makefile lists.
#
# SOURCE OF TRUTH: the source lists and CFLAGS are EXTRACTED from the
# Makefile (never duplicated here), so a change there cannot silently drift
# from what this script compiles.  Only the target triple and output paths
# differ.
#
# usage: tools/stage-guest.sh [-o OUTDIR] [-m MARKER] [-s SENTINEL] [-f] [-N]
#   -f  force the sibling datalog rebuild (cache under OUTDIR)
#   -N  skip the host pre-checks (the binaries are checked by default)
# Env: FX_SSE_FIXTURE (default the recorded responses_simple.sse),
#      DATALOG_DIR (default ../datalog-dafsa)
set -u

fail() { echo "stage-guest: FAIL: $*" >&2; exit 1; }
skip() { echo "stage-guest: SKIP ($*)"; exit 77; }

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || fail "cannot cd to $REPO"
[ -f Makefile ] || fail "no Makefile at $REPO"

OUT="$REPO/build/guest-payload"
MARKER="FX-GUEST-LOOP-OK-8f31"
SENTINEL="guest-loop-probe-8f31"
FORCE=0
PRECHECK=1
while [ $# -gt 0 ]; do
    case "$1" in
        -o) [ $# -ge 2 ] || fail "-o needs a value"; OUT=$2; shift 2 ;;
        -m) [ $# -ge 2 ] || fail "-m needs a value"; MARKER=$2; shift 2 ;;
        -s) [ $# -ge 2 ] || fail "-s needs a value"; SENTINEL=$2; shift 2 ;;
        -f) FORCE=1; shift ;;
        -N) PRECHECK=0; shift ;;
        *) fail "unknown arg '$1' (usage: stage-guest.sh [-o OUTDIR] [-m MARKER] [-s SENTINEL] [-f] [-N])" ;;
    esac
done
DATALOG_DIR="${DATALOG_DIR:-$(cd "$REPO/.." && pwd)/datalog-dafsa}"
FIXTURE="${FX_SSE_FIXTURE:-/var/lib/workspace/vibe-runtime/tests/fixtures/responses_simple.sse}"

command -v zig >/dev/null 2>&1 || skip "zig not found (the guest toolchain)"
command -v python3 >/dev/null 2>&1 || skip "python3 not found (Makefile extraction)"
[ -d "$DATALOG_DIR" ] || skip "sibling datalog-dafsa not found at $DATALOG_DIR"
[ -f "$FIXTURE" ] || fail "recorded SSE fixture not found: $FIXTURE (set FX_SSE_FIXTURE)"

ROOTDIR="$OUT/root"
BINDIR="$ROOTDIR/usr/fx-agent/bin"
mkdir -p "$BINDIR" "$ROOTDIR/usr/fx-agent/cfg" "$OUT" || fail "cannot create $OUT"
# Rebuild the payload tree from scratch: a STALE file left from an earlier
# staging run would join the image silently, and the negative control's whole
# claim is that the payload SET is exactly what this script staged.
[ "$OUT" != "/" ] && [ -n "$OUT" ] || fail "refusing to clean OUT='$OUT'"
rm -rf "$ROOTDIR" || fail "cannot clear $ROOTDIR"
rm -f "$OUT"/fx-agent-service*.dhall || fail "cannot clear the stale service configs"
mkdir -p "$BINDIR" "$ROOTDIR/usr/fx-agent/cfg" || fail "cannot create $BINDIR"

# ─── the Makefile is the source of truth for the build inputs ─────────────
eval "$(python3 - "$REPO/Makefile" <<'PYEOF'
import re, sys, shlex
txt = open(sys.argv[1]).read().split("\n")
def var(name):
    out, on, cur = [], False, ""
    for ln in txt:
        if not on:
            m = re.match(r"^%s\s*:=\s*(.*)$" % re.escape(name), ln)
            if not m:
                continue
            on, cur = True, m.group(1)
        else:
            cur = ln
        if cur.endswith("\\"):
            out.append(cur[:-1]); continue
        out.append(cur); break
    return " ".join(out).strip()
want = ["CFLAGS", "L2_SRC", "L1_SRC", "DHALL_SRC", "YYJSON_SRC", "TOMLC99_SRC"]
vals = {k: var(k) for k in want}
missing = [k for k, v in vals.items() if not v]
if missing:
    sys.stderr.write("stage-guest: FAIL: Makefile variables empty/missing: %s\n" % ",".join(missing))
    sys.exit(1)
if "agent_main_main.c" not in vals["L2_SRC"] and not True:
    pass
for k, v in vals.items():
    print("%s=%s" % (k, shlex.quote(v)))
PYEOF
)" || fail "cannot extract the build inputs from the Makefile"
[ -n "${CFLAGS:-}" ] || fail "CFLAGS extraction produced nothing"

# $(CURDIR) is the Makefile's own expansion; the debug-prefix flags are
# cosmetic and are dropped (they are the only $(CURDIR) users).
GFLAGS=$(printf '%s' "$CFLAGS" | sed -e "s|\\\$(CURDIR)|$REPO|g" \
    -e 's/-ffile-prefix-map=[^ ]*//g' -e 's/-fdebug-prefix-map=[^ ]*//g')
SRC="${L2_SRC:-} ${L1_SRC:-} ${DHALL_SRC:-} ${YYJSON_SRC:-} ${TOMLC99_SRC:-}"
MAIN=src/llm2/agent_main_main.c
[ -f "$MAIN" ] || fail "$MAIN missing (the Makefile's link input)"

# ─── the datalog engine for the guest targets (sibling's own build.zig) ───
# Same invocation the Makefile uses for x86-linux-musl, one target over.  The
# cache + prefix live under OUT, so nothing is written into the sibling.
dl_musl_arch() { # dl_musl_arch ARCH DEST   (ARCH = x86_64 | x86)
    _arch=$1 _dest=$2
    if [ "$FORCE" = 0 ] && [ -f "$_dest/lib/libdatalog.a" ]; then
        echo "stage-guest: reusing $_dest/lib/libdatalog.a"
        return 0
    fi
    echo "stage-guest: building the sibling datalog engine for ${_arch}-linux-musl -> $_dest"
    ( cd "$DATALOG_DIR" && zig build "-Dtarget=${_arch}-linux-musl" -Drelease \
        -p "$_dest" --cache-dir "$_dest/.zig-cache" --build-file zig/build.zig ) \
        >"$OUT/datalog-${_arch}.log" 2>&1
    # the sibling's own dlp target can fail for unrelated reasons; the ARTIFACT
    # is the gate (the Makefile's recipe tolerates the same exit).
    [ -f "$_dest/lib/libdatalog.a" ] \
        || { tail -20 "$OUT/datalog-${_arch}.log" >&2; fail "no libdatalog.a in $_dest (log $OUT/datalog-${_arch}.log)"; }
}
DL64="$OUT/datalog-x86_64-musl"
DL32="$OUT/datalog-x86-musl"

# a guest ELF must be static + stripped (MEASURED precedent: the tool server is
# 2,406,552 B unstripped vs 325,336 B stripped) — assert it, never assume it.
assert_guest_elf() { # assert_guest_elf FILE ARCHDESC
    _f=$1 _d=$2
    [ -f "$_f" ] || fail "$_f missing"
    _t=$(file -b "$_f" 2>/dev/null)
    case "$_t" in
        *"statically linked"*) ;;
        *) fail "$_f is not statically linked: $_t" ;;
    esac
    case "$_t" in
        *"stripped"*) ;;
        *) fail "$_f is not stripped: $_t" ;;
    esac
    case "$_t" in
        *"$_d"*) ;;
        *) fail "$_f is not $_d: $_t" ;;
    esac
}

# ─── fx-agent, x86_64-linux-musl (THE QEMU GUEST ABI) ─────────────────────
dl_musl_arch x86_64 "$DL64"
echo "stage-guest: compiling fx-agent for x86_64-linux-musl"
# shellcheck disable=SC2086
zig cc -target x86_64-linux-musl $GFLAGS -static -s \
    -o "$BINDIR/fx-agent" "$MAIN" $SRC -L"$DL64/lib" -ldatalog \
    || fail "x86_64-linux-musl fx-agent build failed"
assert_guest_elf "$BINDIR/fx-agent" "x86-64"

# ─── fx-agent, x86-linux-musl (the harness's own guest target; the ABI
#     asymmetry control) ──────────────────────────────────────────────────
# The repo's own `make musl` artifact is reused when present (it is the
# thing the v86 lane deploys); otherwise it is built here the same way.
if [ -f "$REPO/build/fx-agent.musl" ] && [ "$FORCE" = 0 ]; then
    cp "$REPO/build/fx-agent.musl" "$BINDIR/fx-agent.i386"
    echo "stage-guest: fx-agent.i386 from the repo's build/fx-agent.musl"
else
    dl_musl_arch x86 "$DL32"
    echo "stage-guest: compiling fx-agent for x86-linux-musl"
    # shellcheck disable=SC2086
    zig cc -target x86-linux-musl $GFLAGS -static -s \
        -o "$BINDIR/fx-agent.i386" "$MAIN" $SRC -L"$DL32/lib" -ldatalog \
        || fail "x86-linux-musl fx-agent build failed"
fi
assert_guest_elf "$BINDIR/fx-agent.i386" "i386"

# ─── fx-verbs-server, x86_64-linux-musl (the tool server) ─────────────────
# tools/build.sh owns the repo's build/ output paths; this compiles the same
# source into the payload directory instead (the shared source is read-only).
VS_SRC="tools/fx-verbs-server.c src/vendor/yyjson/yyjson.c"
[ -f tools/fx-verbs-server.c ] || fail "tools/fx-verbs-server.c missing"
echo "stage-guest: compiling fx-verbs-server for x86_64-linux-musl"
zig cc -target x86_64-linux-musl -static -s -std=c11 -O2 -Wall -Wextra \
    -Isrc/vendor/yyjson -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE \
    -o "$BINDIR/fx-verbs-server" $VS_SRC \
    || fail "x86_64-linux-musl fx-verbs-server build failed"
assert_guest_elf "$BINDIR/fx-verbs-server" "x86-64"

# ─── the harness's RUNTIME config (agents) ────────────────────────────────
# The `args = [] : List Text` annotations are MANDATORY: dhall-c cannot infer
# an unannotated empty list and the whole config fail-opens to empty without
# them (tests/test_resume.sh records the same hazard).
cat > "$ROOTDIR/usr/fx-agent/cfg/config.dhall" <<'DHALL'
{ agents =
  [ { name = "fx"
    , agent_type = "agent"
    , mcp_servers = [] : List { command : Text, args : List Text }
    }
  ]
}
DHALL

# ─── the canned SSE stream (the offline arm's provider) ───────────────────
# The recorded stream, with the assistant text it carries replaced by a UNIQUE
# marker: the console line the guest then prints cannot be produced by any
# other source in the image, so the assertion is unique as well as fireable.
# (Only the exact JSON string "hello" is substituted — the reasoning-text
# sentence that mentions the word is untouched.)
NSUB=$(grep -o '"hello"' "$FIXTURE" | wc -l | tr -d ' ')
[ "$NSUB" -ge 1 ] || fail "the fixture $FIXTURE carries no \"hello\" assistant text to mark"
sed "s/\"hello\"/\"$MARKER\"/g" "$FIXTURE" > "$ROOTDIR/usr/fx-agent/chardev.sse" \
    || fail "cannot write the chardev fixture"
chmod 644 "$ROOTDIR/usr/fx-agent/chardev.sse"
printf '%s\n' "$MARKER"   > "$OUT/marker.txt"
printf '%s\n' "$SENTINEL" > "$OUT/sentinel.txt"
printf '%s\n' "$MARKER"   > "$ROOTDIR/usr/fx-agent/MARKER"
echo "stage-guest: chardev.sse = $FIXTURE with $NSUB occurrence(s) of \"hello\" -> \"$MARKER\""

# ─── the fx-init SERVICE configs ─────────────────────────────────────────
# Shape copied from fx-init/m3/config-console.dhall (the PROVEN console-service
# config: console = Some "console" puts /dev/console on the child's 0/1/2).
#
# TWO configs, because fx-init's boot verdict is a property of the WHOLE
# service set (init.zig's boot_decision: any service in ST_FAILED => FAILED).
# A service that EXITS NONZERO therefore cannot live in the boot whose verdict
# is asserted to be boot-ok — and the harness's exec gate (arm 1) is exactly
# such a service (`fx-agent` with no argv exits 2, by design).  So:
#
#   SERVICE-HEALTHY : heartbeat + fxagent-loop + fxverbs
#       every service either stays alive (fxverbs) or exits 0 (fxagent-loop
#       runs the offline loop to completion) => the boot reaches boot-ok vN.
#   SERVICE-GATE    : heartbeat + fxagent-usage + fxagent-i386
#       fxagent-usage exits 2 and fxagent-i386 cannot exec at all (<= 127), so
#       this boot is boot-FAILED BY CONSTRUCTION — and the assertion pair is
#       the pair of console lines those two services produce, in ONE boot:
#         present : "agent_main: --agent <agent> is required"   (x86_64, ran)
#         absent  : "agent_main: -p <prompt> is required"       (i386, could not)
#       fx-init reports any_failed the moment the first one exits, so the
#       boot-FAILED verdict here is itself evidence the guest's exit status
#       propagated into PID1's state machine.
HEARTBEAT='
        { name = "heartbeat", argv = [ "fakesvc", "ok" ], pkg = Some "fake-service",
            on = "all", restart = Some "always", backoffMs = Some 500,
            probe = None Probe,
            env = None (List { key : Text, value : Text }),
            console = None Text }'

HEALTHY_SVCS="$HEARTBEAT
        , { name = \"fxagent-loop\", argv = [ \"/usr/fx-agent/bin/fx-agent\", \"-p\", \"$SENTINEL\",
                                            \"--agent\", \"fx\", \"--max-turns\", \"3\", \"--output\", \"text\" ], pkg = None Text,
            on = \"all\", restart = Some \"never\", backoffMs = None Natural,
            probe = None Probe,
            env = Some [ { key = \"FX_CHARDEV\", value = \"/usr/fx-agent/chardev.sse\" },
                         { key = \"VIBE_RUNTIME_CONFIG_DIR\", value = \"/usr/fx-agent/cfg\" },
                         { key = \"VIBE_RUNTIME_DIR\", value = \"/fx/disk/agent-data\" },
                         { key = \"HOME\", value = \"/tmp\" }
                       ] : Optional (List { key : Text, value : Text }),
            console = Some \"console\" }
        , { name = \"fxverbs\", argv = [ \"/usr/fx-agent/bin/fx-verbs-server\" ], pkg = None Text,
            on = \"all\", restart = Some \"never\", backoffMs = None Natural,
            probe = None Probe,
            env = None (List { key : Text, value : Text }),
            console = Some \"console\" }"

GATE_SVCS="$HEARTBEAT
        , { name = \"fxagent-usage\", argv = [ \"/usr/fx-agent/bin/fx-agent\" ], pkg = None Text,
            on = \"all\", restart = Some \"never\", backoffMs = None Natural,
            probe = None Probe,
            env = None (List { key : Text, value : Text }),
            console = Some \"console\" }
        , { name = \"fxagent-i386\", argv = [ \"/usr/fx-agent/bin/fx-agent.i386\", \"--agent\", \"arch-probe\" ], pkg = None Text,
            on = \"all\", restart = Some \"never\", backoffMs = None Natural,
            probe = None Probe,
            env = None (List { key : Text, value : Text }),
            console = Some \"console\" }"

write_cfg() { # write_cfg FILE SERVICES
    cat > "$1" <<DHALL
-- generated by tools/stage-guest.sh — do not edit in place
let Probe = < Tcp : Natural | Unix : Text | File : Text >
let Service = { name : Text, argv : List Text, pkg : Optional Text, on : Text,
                restart : Optional Text, backoffMs : Optional Natural,
                probe : Optional Probe,
                env : Optional (List { key : Text, value : Text }),
                console : Optional Text }
let User = { name : Text, uid : Natural, groups : List Text }
in  { hostname = "fixbox"
    , packages = [ "dhake", "fx-init", "fxctl", "fx-activate", "fake-service" ]
    , users = [ { name = "root", uid = 0, groups = [] : List Text } ]
    , services =
        [$2
        ]
    , extraEtc = None (List { path : Text, content : Text })
    , bootGraceMs = Some 15000
    }
DHALL
    [ -s "$1" ] || fail "cannot write the service config $1"
}

write_cfg "$OUT/fx-agent-service-healthy.dhall" "$HEALTHY_SVCS"
write_cfg "$OUT/fx-agent-service-gate.dhall"    "$GATE_SVCS"

# the configs must TYPE-CHECK and parse as fx-init reads them — validated with
# fx-init's OWN parser (zig-out/bin/config_check) before any boot, so a red
# guest cannot be blamed on a malformed service list.
CCHK="${FX_INIT_REPO:-$(cd "$REPO/.." && pwd)/fx-init}/zig/zig-out/bin/config_check"
if [ -x "$CCHK" ]; then
    for c in "$OUT/fx-agent-service-healthy.dhall" "$OUT/fx-agent-service-gate.dhall"; do
        out=$("$CCHK" "$c" 2>&1) || { echo "$out" >&2; fail "config_check rejected $c"; }
        n=$(printf '%s\n' "$out" | grep -c '^service\[[0-9]*\]\.name=')
        [ "$n" -ge 2 ] || fail "config_check saw $n services in $c"
        echo "stage-guest: config_check OK — $(basename "$c"): $n services"
        printf '%s\n' "$out" | grep -E '^service\[[0-9]+\]\.(name|argv|console|pkg)=' | sed 's/^/    /'
    done
else
    echo "stage-guest: WARNING: $CCHK absent — the service configs were not parser-checked" >&2
fi

# ─── host pre-checks: the binaries and the fixture WORK before the boot ────
# These are the arms' PREMISES: if a binary or the fixture is broken here, a
# red guest boot would be unattributable.  Both ABIs must produce their
# signature line ON THE HOST (this host's kernel has IA32 emulation); the
# guest then separates them.
if [ "$PRECHECK" = 1 ]; then
    pc() { # pc FILE ARGS... -> stdout+stderr, rc in $?
        "$1" $2 2>&1 </dev/null
    }
    out=$(pc "$BINDIR/fx-agent" ""); rc=$?
    case "$out" in
        *"agent_main: --agent <agent> is required"*) ;;
        *) fail "host pre-check: $BINDIR/fx-agent printed '$out' (rc=$rc)" ;;
    esac
    out=$(pc "$BINDIR/fx-agent.i386" "--agent arch-probe"); rc=$?
    case "$out" in
        *"agent_main: -p <prompt> is required"*) ;;
        *) fail "host pre-check: fx-agent.i386 printed '$out' (rc=$rc)" ;;
    esac
    echo "stage-guest: host pre-check OK — x86_64 prints the --agent line, i386 prints the -p line"
    PC="$OUT/precheck"
    rm -rf "$PC"; mkdir -p "$PC/cfg" "$PC/data"
    cp "$ROOTDIR/usr/fx-agent/cfg/config.dhall" "$PC/cfg/config.dhall"
    cp "$ROOTDIR/usr/fx-agent/chardev.sse" "$PC/dev.sse"
    out=$(FX_CHARDEV="$PC/dev.sse" VIBE_RUNTIME_CONFIG_DIR="$PC/cfg" \
          VIBE_RUNTIME_DIR="$PC/data" HOME="$PC" \
          "$BINDIR/fx-agent" -p "$SENTINEL" --agent fx --max-turns 3 --output text 2>&1); rc=$?
    [ "$rc" = 0 ] || fail "host pre-check: the offline loop exited rc=$rc: $out"
    [ "$out" = "$MARKER" ] \
        || fail "host pre-check: the offline loop printed '$out', want exactly $MARKER"
    echo "stage-guest: host pre-check OK — the canned stream drives the loop to '$MARKER'"
fi

# ─── the payload listing (evidence) ──────────────────────────────────────
echo "stage-guest: payload -> $OUT"
( cd "$ROOTDIR" && find . -type f -o -type l | LC_ALL=C sort | while IFS= read -r f; do
      printf '  %-42s %10s  %s\n' "$f" "$(wc -c < "$f" 2>/dev/null || echo -)" "$(file -b "$f" 2>/dev/null | cut -c1-46)"
  done )
echo "stage-guest: OK (service configs $OUT/fx-agent-service-{healthy,gate}.dhall)"
