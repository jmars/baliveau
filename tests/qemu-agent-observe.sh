#!/bin/sh
# tests/qemu-agent-observe.sh — THE OBSERVATION LOOP, IN TWO ARMS, IN A GUEST.
#
# WHAT IT PROVES, AND WHY IT IS TWO ARMS.  A never-settling OSCILLATOR was
# measured on B2's arm 2: the agent activates a config that crashes the boot,
# fx-init recovers by republishing older good content AS A NEW HIGHER VERSION
# (content goes back, the version number goes UP), and — because the agent
# service lives in the RESTORED bracket — it re-runs against its FIXED fixture
# and RE-CREATES the failure.  Versions ratchet ~+2/cycle and <store>/.bootlog
# gains a failed line per cycle, forever.  The agent is supposed to LOOK AT THE
# ROLL-FORWARD AND NOT DO IT AGAIN; the harness now MECHANISES that step
# (src/llm2/outcome.h), because the machinery must not re-act blindly even when
# the thing driving it is a canned fixture.
#
# THE RULE (outcome.h), applied at the START of every run:
#     "if the generation I am running in is not the one I activated, my
#      activation failed — do not repeat it",
# made precise against the store's own two plain files:
#     A = the generation the harness's own durable record says it activated
#     C = <store>/.db/snapshots/CURRENT  (the generation this boot runs)
#     A failed in <store>/.bootlog -> ACTIVATION_FAILED: report, stop
#     A ok in the bootlog + done   -> ALREADY_DONE (it took, and the task finished)
#     A ok in the bootlog, no done -> SUPERSEDED: it booted, but nothing on record
#                                     says the TASK finished — say so, stop anyway
#     C == A                       -> RUN (it took)
#     A never judged               -> UNRESOLVED: report, stop (unless a later run
#                                     of the task COMPLETED: complete wins)
# Every stop NAMES ITS WAY OUT in the report (--reconsider, or removing this
# task's lines from the record) — a stop with no escape is a permanent wedge.
# The record (<VIBE_RUNTIME_DIR>/attempts.jsonl, /fx/disk/agent-data on the
# virtio disk) is the ONLY causal link: an agent-driven /bin/fx-activate writes
# no rt_effect and no runtime relation, so the system cannot supply it.
#
#   ARM OBSERVING (disk-obs, image-obs)  — the harness with the loop
#     boot 1  the bracket v_B boots ok; the agent runs its recorded fixture
#             (fx_outcome, fx_write the crasher config, fx_activate) -> a NEW
#             generation v_A the HOST never created, recorded durably.
#     boot 2  the SAME disk: v_A boots and FAILS in grace -> boot-FAILED v_A and
#             "<v_A> failed" in the disk .bootlog.
#     boot 3  fx-init rolls forward to the newest ok generation below v_A (the
#             bracket) under a NEW, HIGHER version v_C.  The agent service is
#             back — and this is where the arms diverge: the harness reads its
#             own record, sees "v_A failed", REPORTS the failure on the console
#             and STOPS.  No activation is issued (NO new session dir on the
#             disk), so nothing new is created.
#     boot 4  v_C again (no roll-forward: its verdict is ok).  The agent service
#             re-runs, observes the same failure again, again does nothing.
#     ASSERTED: exactly ONE failed line in the disk .bootlog, the maximum
#     version on the disk is v_C (the version the ROLL-FORWARD created, not one
#     the agent created), the report is on the boot-3 AND boot-4 consoles, and
#     the disk's session count does not grow after boot 1.  SETTLED.
#
#   ARM BLIND (disk-blind, image-blind) — today's behaviour, as an ARTIFACT
#     the SAME store, the SAME fixture and configs, the SAME boot sequence; the
#     ONLY difference is that the payload's fx-agent was built with
#     -DFX_HARNESS_NO_OBSERVE (make blind), i.e. it records exactly as the real
#     one does but never reads its record back.  It re-runs and re-activates
#     blindly: boot 3 rolls forward to v_C and the agent creates ANOTHER
#     crasher generation v_A2 > v_C; boot 4 boots v_A2 and FAILS -> a SECOND
#     failed line.  ASSERTED: the version keeps climbing past v_C and the
#     .bootlog gains a failed line per cycle — THE RATCHET.
#
# THE DIFFERENCE IS THE PROOF, and both arms are asserted in ONE run: if the
# blind arm did not ratchet, the observing arm would be measuring nothing; if
# the observing arm still ratcheted, the loop would not be closed.  Deterministic,
# offline, no model: the rule is mechanised.
#
# NO CONTROL CHANNEL HERE.  Every assertion is the console (fx-init's own
# verdicts + the agent's own stdout, which its service sends to the console) or
# a disco read-back off the virtio disk (debugfs).  Nothing reads the runtime DB
# — which is the point: the bootlog and CURRENT are plain files.
#
# THE RECOVERY JOURNAL is asserted on BOTH halves here: the SUBSTRATE half
# (fx-init 4d6a8c2 writes <store>/.recovery — one data line per AUTOMATIC
# roll-forward; boot 3's roll-forward MUST be on the disk, published=<the new
# version> from=<the failed one>) and the AGENT half (the harness's
# ACTIVATION_FAILED report carries the count, and the boot-1 fx_outcome reply
# reads the journal through the model's own tool).  An agent that has just been
# refused must SEE that this has happened before, not merely that it happened.
#
# Env: QEMU_BOOT_TIMEOUT (default 120)  QEMU_KEEP=1  FX_INIT_REPO
#      FX_KERNEL_CACHE  OBS_MARKER  OBS_SKIP_BOOT=1 (stage + images only)
set -u

fail() { echo "qemu-agent-observe: FAIL: $*" >&2; exit 1; }
skip() { echo "qemu-agent-observe: SKIP ($*)"; exit 77; }

command -v qemu-system-x86_64 >/dev/null 2>&1 || skip "qemu-system-x86_64 not found"
command -v cpio >/dev/null 2>&1    || skip "cpio not found"
command -v gzip >/dev/null 2>&1    || skip "gzip not found"
command -v sha256sum >/dev/null 2>&1 || skip "sha256sum not found"
command -v timeout >/dev/null 2>&1 || skip "timeout(1) not found"
command -v qemu-img >/dev/null 2>&1 || skip "qemu-img not found (disk store)"
command -v python3 >/dev/null 2>&1 || skip "python3 not found (the fixture)"
command -v zig >/dev/null 2>&1     || skip "zig not found (the guest toolchain)"
command -v strip >/dev/null 2>&1   || skip "strip(1) not found (guest artifacts are stripped)"
command -v file >/dev/null 2>&1    || skip "file(1) not found (ELF class assertions)"
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
[ -n "$DEBUGFS" ] || skip "debugfs not found (e2fsprogs; the disk read-backs are load-bearing)"

cd "$(dirname "$0")/.." || fail "cannot cd to repo root"
REPO="$PWD"
INIT="${FX_INIT_REPO:-$(cd "$REPO/.." && pwd)/fx-init}"
BOOT_TIMEOUT="${QEMU_BOOT_TIMEOUT:-120}"
SETTLE="${QEMU_AGENT_SETTLE:-12}"
[ -d "$INIT" ] || skip "fx-init checkout not found at $INIT (set FX_INIT_REPO)"
PIN="$INIT/scripts/kernel-pin.txt"
[ -f "$PIN" ] || skip "scripts/kernel-pin.txt missing"
MARKER="${OBS_MARKER:-obs-agent-4d17}"
VIBE_DIR="/fx/disk/agent-data"
AGENT_CONFIG="/fx/disk/agent-config.dhall"
OBS_PROMPT="apply the config change to this machine"
OBS_REPORT="OBSERVED OUTCOME"
OBS_ACT_FAILED="THE ACTIVATION THIS HARNESS RECORDED FAILED"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qemuobs.XXXXXX")" || fail mktemp
if [ "${QEMU_KEEP:-0}" = "1" ]; then
    trap 'echo "qemu-agent-observe: scratch kept at $WORK"' EXIT
else
    trap 'rm -rf "$WORK"' EXIT
fi
EVID="${QEMU_AGENT_EVIDENCE_DIR:-$REPO/tests/evidence/qemu-agent-observe}"
mkdir -p "$EVID" || fail "cannot create the evidence dir $EVID"
STORE="$WORK/store"
mkdir -p "$STORE" || fail "cannot create the store"

# ─── pinned kernel (fx-init's own fetcher + pin; never the host's /boot) ───
KCACHE="${FX_KERNEL_CACHE:-$INIT/.kernel-cache}"
KERNEL="$KCACHE/kernel/vmlinuz"
WANT_SHA=$(sed -n 's/^vmlinuz_sha256 //p' "$PIN")
[ -n "$WANT_SHA" ] || skip "kernel pin file malformed"
if [ -r "$KERNEL" ] && [ "$(sha256sum "$KERNEL" | awk '{print $1}')" = "$WANT_SHA" ]; then
    echo "qemu-agent-observe: pinned kernel verified in cache"
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

# ─── the payload (tools/stage-guest.sh owns build/guest-payload/) ─────────
echo "=== qemu-agent-observe: staging the guest payload ==="
sh "$REPO/tools/stage-guest.sh" || fail "tools/stage-guest.sh failed"
PAYLOAD="$REPO/build/guest-payload"
PAYROOT="$PAYLOAD/root"
PL_BIN="$PAYROOT/usr/fx-agent/bin"
for b in fx-agent fx-verbs-server; do
    [ -x "$PL_BIN/$b" ] || fail "payload has no $b"
done
DL64="$PAYLOAD/datalog-x86_64-musl"
[ -f "$DL64/lib/libdatalog.a" ] || fail "no staged x86_64 libdatalog.a at $DL64 (stage-guest)"

# every guest artifact this test ships is STATIC + STRIPPED + the right ELF
# class, and that is ASSERTED, not assumed (the pinned kernel cannot exec i386).
assert_guest_elf() { # assert_guest_elf FILE ARCHDESC
    _f=$1 _d=$2
    [ -f "$_f" ] || fail "$_f missing"
    _t=$(file -b "$_f" 2>/dev/null)
    case "$_t" in *"statically linked"*) ;; *) fail "$_f is not static: $_t" ;; esac
    case "$_t" in *"stripped"*) ;; *) fail "$_f is not stripped: $_t" ;; esac
    case "$_t" in *"$_d"*) ;; *) fail "$_f is not $_d: $_t" ;; esac
}

# ─── THE PRE-FIX ARTIFACT: fx-agent with the observation compiled out ──────
# The SAME sources and the same flags stage-guest.sh uses, plus
# -DFX_HARNESS_NO_OBSERVE (the Makefile's `make blind` target, for the guest
# ABI).  It is the ONLY difference between the two arms' payloads.
echo "=== qemu-agent-observe: building the pre-fix (blind) fx-agent for x86_64-linux-musl ==="
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
    sys.stderr.write("qemu-agent-observe: FAIL: Makefile variables empty: %s\n" % ",".join(missing))
    sys.exit(1)
for k, v in vals.items():
    print("%s=%s" % (k, shlex.quote(v)))
PYEOF
)" || fail "cannot extract the build inputs from the Makefile"
[ -n "${CFLAGS:-}" ] || fail "CFLAGS extraction produced nothing"
GFLAGS=$(printf '%s' "$CFLAGS" | sed -e "s|\\\$(CURDIR)|$REPO|g" \
    -e 's/-ffile-prefix-map=[^ ]*//g' -e 's/-fdebug-prefix-map=[^ ]*//g')
BLIND_SRC="${L2_SRC:-} ${L1_SRC:-} ${DHALL_SRC:-} ${YYJSON_SRC:-} ${TOMLC99_SRC:-}"
BLIND="$WORK/fx-agent-blind"
# shellcheck disable=SC2086
zig cc -target x86_64-linux-musl $GFLAGS -DFX_HARNESS_NO_OBSERVE -static -s \
    -o "$BLIND" src/llm2/agent_main_main.c $BLIND_SRC -L"$DL64/lib" -ldatalog \
    || fail "the blind fx-agent (x86_64-linux-musl) build failed"
assert_guest_elf "$BLIND" "x86-64"
echo "qemu-agent-observe: blind artifact -> $(file -b "$BLIND" | cut -c1-60)"

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
        -not -path "./elm-stuff/*"  -not -name "elm-stuff" \
        -not -path "./dist/*"     -not -name "dist" \
        -not -name "*.o" -not -name "*.a" -not -name "*.so" -not -name "*.com" \
        -not -name "dl-test-*" -not -name ".ape-*" \
        -print0 | cpio -pdm0 "$2" ) >/dev/null 2>&1 \
        || fail "cannot snapshot $1 -> $2"
}
echo "=== qemu-agent-observe: freezing package sources ($INIT + its siblings) ==="
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

# ─── fx-init's guest binaries (x86_64-linux-musl; stripped, class asserted) ─
ZB="$PAYLOAD/init-x86_64-musl/bin"
if [ ! -x "$ZB/fx-init" ] || [ "${QEMU_AGENT_REBUILD_INIT:-0}" = 1 ]; then
    echo "=== qemu-agent-observe: building fx-init's guest binaries (x86_64-linux-musl) ==="
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
# THE CACHE IS A MOVING REF — close it: the build above is SKIPPED when the
# binaries are already there, so a cache from BEFORE fx-init 4d6a8c2 boots a
# guest with NO recovery journal, and the journal assertions below would fail
# with a misleading message.  The binary must CARRY the journal writer (its
# header string) or the gate refuses to run — a stale cache is a loud failure,
# not a silent wrong guest.  (MEASURED: a pre-4d6a8c2 cache made boot 1 read
# "recovery absent" and the failure looked like a reader bug.)
#
# THE GUARD IS A FUNCTION because its FAILING PATH HAS TO BE RUN.  An
# unexercised guard may be INERT — and an inert guard is exactly how the false
# in-guest result got through (the reader was right; the CONTROL was lying).
# init_journal_refusal BIN prints the refusal and returns 1 when BIN does not
# carry the journal writer's header; the SELF-TEST immediately below drives that
# arm against a stub of the same ELF class.
init_journal_refusal() { # init_journal_refusal BIN
    strings "$1" 2>/dev/null | grep -q 'fx-init recovery journal' && return 0
    printf '%s predates the recovery journal (fx-init 4d6a8c2) — rebuild it: QEMU_AGENT_REBUILD_INIT=1 sh tests/qemu-agent-observe.sh\n' "$1"
    return 1
}
JREF=""
JREF="$(init_journal_refusal "$ZB/fx-init")" || fail "$JREF"

# ─── THE GUARD'S OWN FAILING PATH, EXERCISED (not assumed) ────────────────
# A guard nobody has ever seen fail is a guard nobody knows works.  The stub is
# built to the SAME ELF class as the real binary (static, stripped, x86-64-musl)
# so this arm is about THE STRING the guard reads and not about an obviously
# different file.  FAILS if the guard passes a binary that lacks the journal
# writer (INERT), if its refusal does not name QEMU_AGENT_REBUILD_INIT=1, or if
# it refuses the REAL binary (a guard that refuses everything is inert in the
# other direction) — and its premise is asserted: the stub really is the same
# artifact class and really does not carry the string.
# WHAT THIS COVERS: init_journal_refusal (the assertion, its input, its message)
# and the caller's use of its exit status.
# WHAT IT DOES NOT: the in-guest consequence of a stale cache (that the journal
# assertions would then fail on a guest with no journal) — that needs the real
# ~6-minute boot, and is covered by the journal assertions themselves, which are
# what a stale cache would break.
echo "=== qemu-agent-observe: exercising the stale-binary guard's FAILING path ==="
STUB="$WORK/stale-fx-init"
printf 'int main(void) { return 0; }\n' > "$WORK/stale-init.c"
zig cc -target x86_64-linux-musl -std=gnu11 -O2 -static -s -o "$STUB" "$WORK/stale-init.c" \
    || fail "the stale-binary guard's self-test cannot build its stub"
assert_guest_elf "$STUB" "x86-64"
strings "$STUB" 2>/dev/null | grep -q 'fx-init recovery journal' \
    && fail "the guard self-test's stub CARRIES the journal header — the failing arm would pass for the wrong reason"
SREF=""
if SREF="$(init_journal_refusal "$STUB")"; then
    fail "the stale-binary guard PASSED a binary that does not carry the journal writer — THE GUARD IS INERT (a stale cache boots a guest with no journal, and the failure would look like a reader bug)"
fi
case "$SREF" in
    *QEMU_AGENT_REBUILD_INIT=1*) ;;
    *) fail "the stale-binary guard refused the stub but does NOT name the rebuild switch: '$SREF'";;
esac
case "$SREF" in
    *predates*recovery*journal*) ;;
    *) fail "the stale-binary guard's refusal does not say what is stale: '$SREF'";;
esac
init_journal_refusal "$ZB/fx-init" >/dev/null \
    || fail "the stale-binary guard REFUSES the real $ZB/fx-init — the guard is broken, not the cache"
echo "[guard] stale-binary guard EXERCISED: it refuses a same-class stub that lacks the journal header, naming QEMU_AGENT_REBUILD_INIT=1, and still passes the real binary"

# ─── the SECOND stale-binary guard: the staged fx-init must carry the
# PER-BOOT NONCE writer (fx.bootnonce parsing), for the same reason as the
# journal guard: the build above is skipped when the binary is cached, and a
# pre-nonce fx-init would boot a guest whose .bootlog lines carry NO nonce —
# every nonce assertion below would then fail for a reason that looks like a
# reader bug.  Guard-as-function, failing path exercised, same ELF-class stub.
init_nonce_refusal() { # init_nonce_refusal BIN
    strings "$1" 2>/dev/null | grep -q 'fx.bootnonce' && return 0
    printf '%s predates the per-boot nonce (fx-init fx.bootnonce=) — rebuild it: QEMU_AGENT_REBUILD_INIT=1 sh tests/qemu-agent-observe.sh\n' "$1"
    return 1
}
NREF=""
NREF="$(init_nonce_refusal "$ZB/fx-init")" || fail "$NREF"
if NREF_STUB="$(init_nonce_refusal "$STUB" 2>/dev/null)"; then
    fail "the nonce guard PASSED a binary that does not carry the nonce writer — THE GUARD IS INERT (a stale cache boots a nonce-less writer, and the nonce demo below would fail misleadingly)"
fi
case "${NREF_STUB:-}" in
    *QEMU_AGENT_REBUILD_INIT=1*) ;;
    *) fail "the nonce guard's refusal does not name the rebuild switch: '${NREF_STUB:-}'";;
esac
init_nonce_refusal "$ZB/fx-init" >/dev/null \
    || fail "the nonce guard REFUSES the real $ZB/fx-init — the guard is broken, not the cache"
echo "[guard] nonce-writer guard EXERCISED: it refuses a same-class stub lacking fx.bootnonce, naming QEMU_AGENT_REBUILD_INIT=1, and passes the real binary"
KCONFIG="$KCACHE/kernel/config"
if [ -r "$KCONFIG" ] && grep -q '^CONFIG_IA32_EMULATION=y' "$KCONFIG"; then
    fail "the pinned kernel HAS IA32 emulation — the guest-ABI premise is void, re-read this lane"
fi
echo "qemu-agent-observe: fx-init is x86_64 static: $(file -b "$ZB/fx-init" | cut -c1-52)"

# ─── the audit seat (host side), for the REAL-STORE boot-accounting demo ──
# fx-audit correlates the disk .bootlog's growth with the boots THIS GATE
# starts (the hypervisor's own count).  It shells fxstore for its record
# reads; without a host fxstore the demonstration is SKIPPED with a loud
# line (the seat's discriminations live in tests/test_fx_audit.sh, which
# hard-requires fxstore) — the observation-loop assertions are unaffected.
make -s build/fx-audit >/dev/null || fail "cannot build build/fx-audit"
AUDIT_BIN="$REPO/build/fx-audit"
[ -x "$AUDIT_BIN" ] || fail "no $AUDIT_BIN"
[ "$AUDIT_BIN" -nt "$REPO/tools/fx-audit.c" ] \
    || fail "$AUDIT_BIN is older than tools/fx-audit.c — a stale cached binary answered for the seat; rm -rf build and re-run"
grep -aq 'no nonce the host issued for a boot in this window' "$AUDIT_BIN" \
    || fail "STALE BINARY: $AUDIT_BIN does not carry this source's nonce-binding message — the seat was not built from the per-boot-nonce tools/fx-audit.c"
FXSTORE_AUDIT="$SIBS/fxstore/zig-out/bin/fxstore"
if [ ! -x "$FXSTORE_AUDIT" ]; then
    echo "qemu-agent-observe: LOUD: fxstore missing at $FXSTORE_AUDIT — the REAL-STORE audit demonstration is SKIPPED (build the sibling: cd ../fxstore/zig && zig build); tests/test_fx_audit.sh carries the seat's full discriminations"
    FXSTORE_AUDIT=""
fi

# extract_store DEST-DIR — the disk's /store tree to a host directory
# (debugfs rdump; the audit reads a host view of the store exactly as it
# reads a host view of any record)
extract_store() {
    rm -rf "$1"; mkdir -p "$1"
    "$DEBUGFS" -R "rdump /store $1" "$DISK" >/dev/null 2>&1
    [ -d "$1/store" ] || { ls -la "$1" 2>/dev/null; fail "audit: rdump extracted no /store from $DISK into $1"; }
}

# ─── provisioning (toolchain-free path; qemu_ctrl.sh's shape) ─────────────
echo "=== qemu-agent-observe: provisioning the store (toolchain-free) ==="
export FX_SIBLINGS="${FX_SIBLINGS:-$SIBS}"
DL="$SIBS/datalog-dafsa/zig-out/lib"
[ -f "$DL/libdatalog.so" ] || skip "libdatalog.so missing at $DL"
[ -x "$SIBS/dhake/dhake.com" ] || skip "prebuilt dhake.com missing"
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
        *)              : > "$STORE/$pd/.provisioned-by-qemu-agent-observe" ;;
    esac
done

# ─── the configs ──────────────────────────────────────────────────────────
# THE CRASHER: what the AGENT writes and activates (the fixture carries it
# verbatim).  One service that exits 7 -> fx-init's verdict is fail-closed
# inside the grace window.  It carries NO agent service, so the failing
# generation cannot re-run the agent by itself.
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
{
    svc_head
    cat <<DHALL
in  { hostname = "obs-crasher"
    , packages = [ "dhake", "fx-init", "fxctl", "fx-activate", "fake-service" ]
    , users = [ { name = "root", uid = 0, groups = [] : List Text } ]
    , services =
        [ { name = "obscrasher", argv = [ "fakesvc", "exit", "7" ], pkg = Some "fake-service",
            on = "all", restart = Some "never", backoffMs = None Natural,
            probe = None Probe,
            env = None (List { key : Text, value : Text }),
            console = Some "console" }
        ]
    , extraEtc = None (List { path : Text, content : Text })
    , bootGraceMs = Some 15000
    , agentService = None Text
    }
DHALL
} > "$WORK/crasher.dhall" || fail "cannot write the crasher config"

# THE BRACKET: the healthy generation the two arms boot from, and the one a
# roll-forward lands on.  It carries the AGENT SERVICE — which is exactly why
# the oscillator re-runs: the restored bracket still runs the agent.
agent_svc() { # agent_svc FIXTURE -> the obsagent service row (Dhall)
    cat <<DHALL
, { name = "obsagent", argv = [ "/usr/fx-agent/bin/fx-agent", "-p", "$OBS_PROMPT",
                                "--agent", "fx", "--max-turns", "2", "--output", "text" ], pkg = None Text,
            on = "all", restart = Some "never", backoffMs = None Natural,
            probe = None Probe,
            env = Some [ { key = "FX_CHARDEV", value = "$1" },
                         { key = "VIBE_RUNTIME_CONFIG_DIR", value = "/usr/fx-agent/cfg" },
                         { key = "VIBE_RUNTIME_DIR", value = "$VIBE_DIR" },
                         { key = "HOME", value = "/tmp" }
                       ] : Optional (List { key : Text, value : Text }),
            console = Some "console" }
DHALL
}

# ─── THE AGENT PIN (substrate-owned; replaces the console-ness text search) ─
# The harness's refusal EXITS 0, and fx-init pins "failed" for a service that
# exits during the grace window ONLY when that service is NON-console — it
# ignores the exit status entirely.  A NON-console agent would turn every
# refusal into a NEW roll-forward oscillator: the refusal pins v_C failed on
# the rolled-forward generation, the next boot rolls forward, the agent
# refuses again.  The rule the old TEXT search approximated (matching the
# `console = Some "console"` assignment on fx-agent rows, comment-stripped)
# now lives in the SUBSTRATE: fx-init's config parser REQUIRES an
# agentService field and refuses a declared agent that is not a console
# service, at config-check/activation, before any boot.  The pin asserts the
# DECLARATION through the real parser binary and proves it can FAIL, by
# demanding the substrate REFUSE (a) the same config with the declaration
# OMITTED and (b) the same config with the agent row turned NON-console,
# naming the service.  A stale config_check (one that still accepts either
# mutant) fails the pin loudly — that is intentional.
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
        $(agent_svc /usr/fx-agent/arm.sse)
        ]
    , extraEtc = None (List { path : Text, content : Text })
    , bootGraceMs = Some 30000
    , agentService = Some "obsagent"
    }
DHALL
} > "$WORK/bracket.dhall" || fail "cannot write the bracket config"

# EVERY payload config DECLARES its agent (the bracket names obsagent; the
# crasher declares None — an agent-free config must say so, not default).
agent_pin "$WORK/bracket.dhall" "obsagent"
agent_pin "$WORK/crasher.dhall" "-"

CCHK="$INIT/zig/zig-out/bin/config_check"
if [ -x "$CCHK" ]; then
    for c in "$WORK/crasher.dhall" "$WORK/bracket.dhall"; do
        out=$("$CCHK" "$c" 2>&1) || { echo "$out" >&2; fail "config_check rejected $c"; }
        echo "qemu-agent-observe: config_check OK — $(basename "$c"): $(printf '%s\n' "$out" | grep -c '^service\[[0-9]*\]\.name=') service(s)"
    done
else
    echo "qemu-agent-observe: WARNING: $CCHK absent — the configs were not parser-checked" >&2
fi

# ─── the payload roots + the recorded fixture ─────────────────────────────
# TWO roots, identical except for the fx-agent binary: the OBSERVING build and
# the BLIND (pre-fix) one.  Both carry the same agent config and the same
# recorded SSE stream, so nothing but the binary can explain a different outcome.
for variant in obs blind; do
    R="$WORK/root-$variant"
    cp -a "$PAYROOT" "$R" || fail "cannot copy the payload rootdir ($variant)"
    mkdir -p "$R/usr/fx-agent/cfg" || fail "cannot create the agent config dir"
    if [ "$variant" = blind ]; then
        cp "$BLIND" "$R/usr/fx-agent/bin/fx-agent" || fail "cannot install the blind fx-agent"
        chmod 755 "$R/usr/fx-agent/bin/fx-agent"
        assert_guest_elf "$R/usr/fx-agent/bin/fx-agent" "x86-64"
    fi
    cat > "$R/usr/fx-agent/cfg/config.dhall" <<DHALL
{ agents =
  [ { name = "fx"
    , agent_type = "agent"
    , mcp_servers =
      [ { command = "/usr/fx-agent/bin/fx-verbs-server"
        , args = [] : List Text
        , env = Some { FX_AGENT_WRITABLE = "$AGENT_CONFIG" }
        }
      ]
    }
  ]
}
DHALL
    [ -s "$R/usr/fx-agent/cfg/config.dhall" ] || fail "cannot write the agent config ($variant)"
done

# THE FIXTURE (the model, canned): the SAME stream for both arms.  Three calls,
# in order — READ THE OUTCOME (fx_outcome: the boot history + CURRENT, read
# through the tool server's own new verb), write the crasher config, activate
# it.  The chardev transport SEEKs to 0 before every turn, so every boot replays
# the same stream, and --max-turns 2 is exactly one dispatch round.
cat > "$WORK/mkfixture.py" <<'PYEOF'
import json, sys
out, text, cfg_path, cfg_file = sys.argv[1:5]
content = open(cfg_file).read()
def ev(name, obj):
    return "event: %s\ndata: %s\n\n" % (name, json.dumps(obj))
# THE 4TH CALL IS THE RECORD-TAMPERING PROBE (SF1, in-guest): fx_write the
# harness's own durable record — the exact move that resurrects the oscillator
# (read the record, rewrite it without your task's lines; the next boot sees
# no attempt, decides RUN and re-issues the crasher).  The tool server must
# REFUSE it inside the guest; the assertions on boot 1 check the refusal AND
# that the declared config write (call 2) still succeeded.
FORGED = "1799999999 0000000000000000 done - - 0 -\nFORGED-RECORD-PROBE"
calls = [
    ("call_obs_outcome",  "fx_outcome",  {}),
    ("call_obs_write",    "fx_write",    {"path": cfg_path, "content": content}),
    ("call_obs_activate", "fx_activate", {"config": cfg_path}),
    ("call_obs_tamper",   "fx_write",    {"path": "/fx/disk/agent-data/attempts.jsonl",
                                          "content": FORGED}),
]
s = [ev("response.created", {"type": "response.created",
                             "response": {"id": "obs-fixture", "status": "in_progress"}}),
     ev("response.output_item.added",
        {"type": "response.output_item.added", "output_index": 0,
         "item": {"type": "message", "id": "m0", "status": "in_progress"}}),
     ev("response.output_text.delta",
        {"type": "response.output_text.delta", "delta": text,
         "item_id": "m0", "output_index": 0}),
     ev("response.output_item.done",
        {"type": "response.output_item.done", "output_index": 0,
         "item": {"type": "message", "id": "m0", "status": "completed"}})]
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
    s.append(ev("response.output_item.done",
                {"type": "response.output_item.done", "output_index": idx,
                 "item": {"type": "function_call", "id": "fc%d" % i,
                          "status": "completed", "call_id": cid,
                          "name": name, "arguments": a}}))
s.append(ev("response.completed",
            {"type": "response.completed",
             "response": {"id": "obs-fixture", "status": "completed"}}))
open(out, "w").write("".join(s))
PYEOF
TEXT_MARKER="OBS-AGENT-RAN-$MARKER"
for variant in obs blind; do
    python3 "$WORK/mkfixture.py" "$WORK/root-$variant/usr/fx-agent/arm.sse" \
        "$TEXT_MARKER" "$AGENT_CONFIG" "$WORK/crasher.dhall" \
        || fail "cannot build the fixture ($variant)"
    grep -q 'fx_activate' "$WORK/root-$variant/usr/fx-agent/arm.sse" || fail "the fixture ($variant) has no fx_activate"
    grep -q 'fx_outcome'  "$WORK/root-$variant/usr/fx-agent/arm.sse" || fail "the fixture ($variant) has no fx_outcome read"
    grep -q 'obscrasher'  "$WORK/root-$variant/usr/fx-agent/arm.sse" || fail "the fixture ($variant) carries no crasher"
done
echo "qemu-agent-observe: one fixture, two payloads: the observing fx-agent and the blind (-DFX_HARNESS_NO_OBSERVE) one"

# ─── ONE activation on ONE store, then the two images ─────────────────────
activate() { # activate CFG -> "activated <hash> as version N"
    LD_LIBRARY_PATH="$DL" "$ZB/fx-activate" --store "$STORE" \
        --package-set "$PKGSET" --config "$1" 2>&1
}
version_of() { sed -n 's/.*as version \([0-9][0-9]*\).*/\1/p' | head -1; }
image() { # image ROOTDIR LISTFILE OUT
    sh "$INIT/tests/mkinitramfs.sh" -s "$STORE" -r "$1" -k "$KERNEL" -o "$3" -l "$2" -p "$PKGSET" \
        || fail "mkinitramfs failed ($3)"
}

echo "=== qemu-agent-observe: activating the BRACKET (the healthy, agent-bearing generation) ==="
OUT_B=$(activate "$WORK/bracket.dhall") || fail "activate bracket failed: $OUT_B"
V_B=$(echo "$OUT_B" | version_of); [ -n "$V_B" ] || fail "cannot parse v_B from: $OUT_B"
echo "$OUT_B"
image "$WORK/root-obs"   "$WORK/img-obs.list"   "$WORK/img-obs.cpio.gz"
image "$WORK/root-blind" "$WORK/img-blind.list" "$WORK/img-blind.cpio.gz"
for want in usr/fx-agent/bin/fx-agent usr/fx-agent/bin/fx-verbs-server \
            usr/fx-agent/cfg/config.dhall usr/fx-agent/arm.sse; do
    grep -qx "$want" "$WORK/img-obs.list"   || fail "image obs does not carry $want"
    grep -qx "$want" "$WORK/img-blind.list" || fail "image blind does not carry $want"
done
echo "qemu-agent-observe: both images carry the payload; bracket generation v$V_B"

FXD=$(ls -d "$STORE"/*-fx-init | head -1)
RDINIT="/fx/store/$(basename "$FXD")/fx-init"

# ─── the boot driver (no chardev: every assertion is the console or the disk) ─
qemu_pid=""
# THE HOST'S PER-BOOT NONCE LEDGER — the hypervisor's own record of the
# token it issued for each launch, handed to the guest on the kernel
# command line (fx.bootnonce=) and NEVER written inside the guest.  This
# gate mints it from /dev/urandom per launch (unpredictable, exactly the
# live property the audit's window binding rests on; the fixture gates use
# deterministic tokens because their lines are hand-fabricated to match).
NONCE_LEDGER="$WORK/host-nonces.led"
: > "$NONCE_LEDGER"
NONCE_N=0
boot() { # boot IMG CONLOG
    _img=$1 _con=$2
    : > "$_con"
    NONCE_N=$((NONCE_N + 1))
    BOOT_NONCE=$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
    [ -n "$BOOT_NONCE" ] || fail "cannot mint the boot nonce (no /dev/urandom?)"
    echo "$NONCE_N $BOOT_NONCE" >> "$NONCE_LEDGER"
    echo "qemu-agent-observe: [host] boot #$NONCE_N: fx.bootnonce=$BOOT_NONCE issued"
    qemu-system-x86_64 \
        -machine q35 -accel kvm -cpu host -m 2048 -smp 1 \
        -kernel "$KERNEL" -initrd "$_img" \
        -append "console=ttyS0,115200 rdinit=$RDINIT fx.store=/fx/store fx.bootnonce=$BOOT_NONCE panic=-1 oops=panic" \
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
read_from_disk() { "$DEBUGFS" -R "dump $1 $2" "$DISK" >/dev/null 2>&1; }
# the disk's own root IS the guest's /fx/disk (store/ and agent-data/ live there)
bootlog_max_version() { awk '$1+0 > m { m = $1+0 } END { print m+0 }' "$1"; }
bootlog_failed_count() { grep -c ' failed ' "$1" || true; }
session_count() { # session_count BOOTLOG-OUT — the sessions ON THE DISK
    "$DEBUGFS" -R "ls -p /agent-data/sessions" "$DISK" 2>/dev/null \
        | sed -n 's|^/[0-9]*/[0-9]*/[0-9]*/[0-9]*/\([^/.][^/]*\)/*$|\1|p' | wc -l | tr -d ' '
}

if [ "${OBS_SKIP_BOOT:-0}" = "1" ]; then
    echo "qemu-agent-observe: OBS_SKIP_BOOT=1 — staging complete (images in $WORK), v_B=$V_B"
    echo "qemu-agent-observe: PASS (stage-only)"
    exit 0
fi

# ═══ ARM OBSERVING — the loop closes ═════════════════════════════════════
DISK="$WORK/disk-obs.img"; new_disk "$DISK"
echo "=== qemu-agent-observe: [obs] boot 1 — the bracket v$V_B; the agent writes and activates the crasher ==="
boot "$WORK/img-obs.cpio.gz" "$WORK/obs-1.log"
cp "$WORK/obs-1.log" "$EVID/obs-boot1-console.log"
grep -n 'disk store mounted\|boot-ok\|boot-FAILED\|OBS-AGENT-RAN\|fakesvc exit' "$WORK/obs-1.log" | head -12
grep -q "fx-init: boot-ok v$V_B" "$WORK/obs-1.log" \
    || { tail -30 "$WORK/obs-1.log"; halt; fail "[obs] boot 1: want boot-ok v$V_B (the bracket's own verdict: an agent-driven activation is durable, NOT hot-applied)"; }
grep -qF "$TEXT_MARKER" "$WORK/obs-1.log" \
    || { tail -40 "$WORK/obs-1.log"; halt; fail "[obs] boot 1: the agent never ran (no '$TEXT_MARKER' on the console)"; }
halt
# the agent's own durable record, read back OFF THE DISK: this file IS the
# causal link, and it is only useful because it is on the virtio disk.
read_from_disk "/agent-data/attempts.jsonl" "$WORK/obs-1-attempts.txt"
cp "$WORK/obs-1-attempts.txt" "$EVID/obs-boot1-attempts.txt"
[ -s "$WORK/obs-1-attempts.txt" ] \
    || { cat "$WORK/obs-1-attempts.txt"; fail "[obs] boot 1: no durable activation record on the disk"; }
V_A=$(sed -n 's/.* result .* \([0-9][0-9]*\) .*/\1/p' "$WORK/obs-1-attempts.txt" | head -1)
[ -n "$V_A" ] || { cat "$WORK/obs-1-attempts.txt"; fail "[obs] boot 1: no recorded activation OUTCOME on the disk"; }
[ "$V_A" -gt "$V_B" ] || fail "[obs] boot 1: the agent's generation v$V_A is not above the bracket v$V_B"
grep -q " attempt " "$WORK/obs-1-attempts.txt" || fail "[obs] boot 1: no attempt line (the intent must be durable BEFORE the call)"
# NO `done` MARKER: the guest's own recorded stream is replayed every turn, so
# the loop's last allowed turn still carries tool calls that are never dispatched
# — the run is TURN-LIMITED, it did not finish the task, and claiming otherwise
# would make the next boot call an unfinished task COMPLETE and refuse to
# continue it.  The harness must SAY SO on the console (its stderr is the
# service's console here), which is what makes this an assertion about the
# end-state rather than about a missing feature.
grep -q " done " "$WORK/obs-1-attempts.txt" \
    && { cat "$WORK/obs-1-attempts.txt"; fail "[obs] boot 1: a TURN-LIMITED run recorded 'done' — the next boot would call this unfinished task COMPLETE"; }
grep -q "turn limit" "$WORK/obs-1.log" \
    || { grep -n 'agent_main' "$WORK/obs-1.log" | head -5; fail "[obs] boot 1: the turn-limited run did not SAY so on the console"; }
# THE TASK<->AGENT BINDING must be on the disk record too: it is what makes a
# DRIFTED task identity (a prompt that varies per boot, which silently disables
# the loop) observable at all.
OBS_TASK=$(awk '$3=="agent"{print $2; exit}' "$WORK/obs-1-attempts.txt")
[ -n "$OBS_TASK" ] \
    || { cat "$WORK/obs-1-attempts.txt"; fail "[obs] boot 1: the disk record carries no task<->agent binding"; }
echo "$OBS_TASK" | grep -Eq '^[0-9a-f]{16}$' \
    || { cat "$WORK/obs-1-attempts.txt"; fail "[obs] boot 1: the bound task id '$OBS_TASK' is not 16 hex"; }
S1=$(session_count); [ "$S1" = 1 ] || fail "[obs] boot 1: expected 1 session on the disk, got $S1"
# the fixture's FIRST call was the new verb, reading fx-init's REAL store
SID=$( "$DEBUGFS" -R "ls -p /agent-data/sessions" "$DISK" 2>/dev/null \
       | sed -n 's|^/[0-9]*/[0-9]*/[0-9]*/[0-9]*/\([^/.][^/]*\)/*$|\1|p' | head -1 )
read_from_disk "/agent-data/sessions/$SID/messages.jsonl" "$WORK/obs-1-transcript.jsonl"
cp "$WORK/obs-1-transcript.jsonl" "$EVID/obs-boot1-transcript.jsonl"
grep -q 'fx_outcome' "$WORK/obs-1-transcript.jsonl" || fail "[obs] boot 1: the fixture's fx_outcome call is not in the transcript"
grep -q "current $V_B" "$WORK/obs-1-transcript.jsonl" \
    || { grep -o 'exit=0.current [0-9]*' "$WORK/obs-1-transcript.jsonl" | head -3; fail "[obs] boot 1: the fx_outcome tool result does not report the guest's real CURRENT (v$V_B)"; }
# THE RECOVERY JOURNAL THROUGH THE MODEL'S OWN TOOL: fx-init creates it (with
# its definition header, zero data lines) on EVERY boot from the first, so the
# boot-1 reply must read "recoveries 0" — the machine saying "never recovered",
# which is a DIFFERENT state than "no journal".  FAILS if the guest's fx-init
# predates the journal (the reply would say "recovery absent" — a stale cached
# guest build) or the verb does not read the file at all (no recoveries line).
grep -q 'recoveries 0' "$WORK/obs-1-transcript.jsonl" \
    || { grep -o 'recover.\{0,60\}' "$WORK/obs-1-transcript.jsonl" | head -3; \
         fail "[obs] boot 1: the fx_outcome reply does not read the recovery journal as ZERO — a store that has never recovered is a measurement, not an absence (stale fx-init guest build?)"; }
# THE RECORD IS NOT MODEL-WRITABLE, IN THE GUEST (SF1): the fixture's 4th call
# fx_writes the record path itself.  The refusal must be IN THE TRANSCRIPT
# (naming the host-declared set), the forged content must be NOWHERE in the
# durable record on the disk, and the agent's own CONFIG write (the path the
# host declared) must still have SUCCEEDED — a fix that refused it would have
# broken the product to close the hole.
grep -q 'fx_write REFUSED' "$WORK/obs-1-transcript.jsonl" \
    || { grep -o 'fx_write.\{0,90\}' "$WORK/obs-1-transcript.jsonl" | head -4; \
         fail "[obs] boot 1: the in-guest fx_write of the RECORD was not REFUSED — the writable set does not hold in the guest"; }
grep -q 'FX_AGENT_WRITABLE' "$WORK/obs-1-transcript.jsonl" \
    || fail "[obs] boot 1: the record-write refusal does not name the host-declared set"
grep -q 'FORGED-RECORD-PROBE' "$WORK/obs-1-attempts.txt" \
    && { cat "$WORK/obs-1-attempts.txt"; fail "[obs] boot 1: forged content REACHED the durable record — the model can erase its own history in the guest"; }
grep -q "bytes to $AGENT_CONFIG" "$WORK/obs-1-transcript.jsonl" \
    || { grep -o 'wrote [0-9]* bytes.\{0,50\}' "$WORK/obs-1-transcript.jsonl" | head -3; \
         fail "[obs] boot 1: the agent's own CONFIG write was refused — the guest's writable set broke the agent's one legitimate write"; }
echo "qemu-agent-observe: [obs] boot 1 GREEN — the agent READ the outcome through fx_outcome (current v$V_B),"
echo "                    wrote + ACTIVATED the crasher: v$V_A (hash recorded in the transcript), and its"
echo "                    record ($(wc -l < "$WORK/obs-1-attempts.txt") lines) is ON THE DISK at /agent-data/attempts.jsonl"
echo "                    — and its fx_write of the RECORD ITSELF was refused in-guest (FX_AGENT_WRITABLE named)"

# ── the audit seat ENROLLS against the REAL store, with the host's OWN
#    boot count: this gate has started exactly ONE boot on this disk.  The
#    count is not read from anywhere in the guest — the gate is the
#    hypervisor here, and its count is the off-disk anchor.
if [ -n "$FXSTORE_AUDIT" ]; then
    extract_store "$WORK/audit-ext1"
    FXSTORE_BIN="$FXSTORE_AUDIT" "$AUDIT_BIN" --store "$WORK/audit-ext1/store" \
        --obs-file "$WORK/audit-obs.obs" --boots 1 --nonces "$NONCE_LEDGER" > "$WORK/audit1.out" 2>&1
    _rc=$?
    cp "$WORK/audit1.out" "$EVID/obs-audit-enroll.out"
    [ "$_rc" = 0 ] || { cat "$WORK/audit1.out"; fail "[obs] audit: enrollment against the real store after boot 1 exited $_rc (a store written only by the REAL writers must audit coherent)"; }
    grep -q 'ENROLLING' "$WORK/audit1.out" \
        || fail "[obs] audit: the first run did not enroll"
    grep -q '^VERDICT: coherent$' "$WORK/audit1.out" \
        || fail "[obs] audit: enrollment verdict is not coherent"
    echo "qemu-agent-observe: [obs] audit ENROLLED against the real store after boot 1 (--boots 1 + the nonce ledger, coherent)"
fi

echo "=== qemu-agent-observe: [obs] boot 2 — the crasher's generation v$V_A boots and FAILS ==="
boot "$WORK/img-obs.cpio.gz" "$WORK/obs-2.log"
cp "$WORK/obs-2.log" "$EVID/obs-boot2-console.log"
grep -n 'disk store mounted\|boot-ok\|boot-FAILED\|fakesvc exit\|obsagent' "$WORK/obs-2.log" | head -12
grep -q "fx-init: disk store mounted (current v$V_A)" "$WORK/obs-2.log" \
    || { tail -30 "$WORK/obs-2.log"; halt; fail "[obs] boot 2: the disk's CURRENT is not the agent's v$V_A"; }
grep -q "fx-init: boot-FAILED v$V_A" "$WORK/obs-2.log" \
    || { tail -30 "$WORK/obs-2.log"; halt; fail "[obs] boot 2: want boot-FAILED v$V_A (the crasher must fail in grace)"; }
halt
read_from_disk "/store/.bootlog" "$WORK/obs-2-bootlog.txt"
cp "$WORK/obs-2-bootlog.txt" "$EVID/obs-boot2-bootlog.txt"
echo "--- [obs] boot 2: the disk .bootlog ---"; sed 's/^/    /' "$WORK/obs-2-bootlog.txt"
grep -q "^$V_A failed " "$WORK/obs-2-bootlog.txt" \
    || { cat "$WORK/obs-2-bootlog.txt"; fail "[obs] boot 2: no '$V_A failed' line in the disk .bootlog"; }
# THE WRITER PROOF, on the real guest's own bytes: every line the real
# fx-init appended carries the nonce the HOST issued for the boot that
# wrote it (latched from this launch's fx.bootnonce=), and PID1 ECHOED
# the nonce on the console.  This is the strongest form of the writer half:
# not a fixture, the live chain host-ledger -> kernel cmdline -> PID1 ->
# the durable record.
ledger_nonce() { awk -v n="$1" '$1 == n { print $2; exit }' "$NONCE_LEDGER"; }
_b=1
while [ "$_b" -le 2 ]; do
    _nb=$(ledger_nonce "$_b")
    [ -n "$_nb" ] || fail "[obs] bootlog nonce: the ledger has no nonce for boot $_b"
    grep -q " $_nb\$" "$WORK/obs-2-bootlog.txt" \
        || { cat "$WORK/obs-2-bootlog.txt"; fail "[obs] boot $_b: no .bootlog line carries the host-issued nonce $_nb — the real writer did not stamp the per-boot nonce"; }
    grep -q "fx-init: boot nonce $_nb" "$WORK/obs-$_b.log" \
        || fail "[obs] boot $_b: PID1 did not echo its nonce on the console"
    _b=$((_b + 1))
done
echo "qemu-agent-observe: [obs] WRITER PROOF: boots 1-2's .bootlog lines carry the host-issued nonces, and PID1 echoed each on the console"

echo "=== qemu-agent-observe: [obs] boot 3 — roll forward to the bracket under a NEW version; the agent OBSERVES and STOPS ==="
boot "$WORK/img-obs.cpio.gz" "$WORK/obs-3.log"
cp "$WORK/obs-3.log" "$EVID/obs-boot3-console.log"
grep -n 'disk store mounted\|rolling forward\|boot-ok\|boot-FAILED\|OBS-AGENT-RAN\|OBSERVED OUTCOME\|NOT REPEATING' "$WORK/obs-3.log" | head -20
V_TGT=$(sed -n "s/.*fx-init: stale failed for v$V_A; rolling forward to v\([0-9][0-9]*\).*/\1/p" "$WORK/obs-3.log" | head -1)
[ -n "$V_TGT" ] || { tail -30 "$WORK/obs-3.log"; halt; fail "[obs] boot 3: no roll-forward line for v$V_A"; }
[ "$V_TGT" = "$V_B" ] || { halt; fail "[obs] boot 3: rolled to v$V_TGT, want the previous ok generation v$V_B"; }
V_C=$(sed -n 's/.*fx-init: boot-ok v\([0-9][0-9]*\).*/\1/p' "$WORK/obs-3.log" | head -1)
[ -n "$V_C" ] || { tail -30 "$WORK/obs-3.log"; halt; fail "[obs] boot 3: no boot-ok after the roll-forward"; }
[ "$V_C" -gt "$V_A" ] || fail "[obs] boot 3: rolled v$V_C not above v$V_A (not a roll FORWARD)"
# THE AGENT SERVICE RAN (that is why the failure is reportable at all) — but its
# FIXTURE DID NOT: the harness reads its own record BEFORE the loop, so the
# canned stream is never fetched.  That absence IS the observation loop working.
grep -qF "$TEXT_MARKER" "$WORK/obs-3.log" \
    && { grep -nF "$TEXT_MARKER" "$WORK/obs-3.log" | head -3; halt; fail "[obs] boot 3: the fixture RAN in the restored bracket — the harness did not observe before acting"; }
grep -qF "$OBS_REPORT" "$WORK/obs-3.log" \
    || { tail -40 "$WORK/obs-3.log"; halt; fail "[obs] boot 3: the harness did not REPORT the outcome"; }
grep -qF "$OBS_ACT_FAILED" "$WORK/obs-3.log" \
    || { tail -40 "$WORK/obs-3.log"; halt; fail "[obs] boot 3: the report does not name the FAILED activation"; }
grep -qF "NOT REPEATING IT" "$WORK/obs-3.log" \
    || { tail -40 "$WORK/obs-3.log"; halt; fail "[obs] boot 3: the report does not say the activation is not being repeated"; }
# THE PROMPT IS THE TASK'S IDENTITY — and the loop only works while that identity
# is BOOT-INVARIANT.  This boot's task id (FNV-1a-64 of agent+prompt) must be the
# very id the record holds, or the boot could not have matched the record at all
# (it would have re-run the fixture).  Asserted on the REAL guest payload, because
# a prompt with anything boot-varying in it makes every boot a new task and the
# loop silently inert — the invariant the whole unit rests on, measured here
# instead of being prose in a README.
grep -q "task     : $OBS_TASK (agent fx)" "$WORK/obs-3.log" \
    || { grep -n 'task     :' "$WORK/obs-3.log" | head -3; halt; fail "[obs] boot 3: the report names a DIFFERENT task id than the disk record ($OBS_TASK) — the prompt is not boot-invariant and the observation loop is inert"; }
halt
read_from_disk "/store/.bootlog" "$WORK/obs-3-bootlog.txt"
cp "$WORK/obs-3-bootlog.txt" "$EVID/obs-boot3-bootlog.txt"
echo "--- [obs] boot 3: the disk .bootlog ---"; sed 's/^/    /' "$WORK/obs-3-bootlog.txt"
# THE RECOVERY JOURNAL, SUBSTRATE HALF: boot 3's roll-forward is the machine's
# FIRST automatic recovery, so the journal holds EXACTLY ONE data line, and it
# must name THIS roll-forward: published=<the NEW version v$V_C> from=<the
# FAILED v$V_A> (the writer's argument order — recovery_append(g_current_version
# AFTER the republish, v_failed captured BEFORE it)).  FAILS if the guest's
# fx-init predates the journal (file absent), if the guardrail refused the
# roll-forward (nothing appended — but then the boot could not be running v_C),
# or if the reader misparses the line.
read_from_disk "/store/.recovery" "$WORK/obs-3-recovery.txt"
cp "$WORK/obs-3-recovery.txt" "$EVID/obs-boot3-recovery.txt"
echo "--- [obs] boot 3: the disk .recovery ---"; sed 's/^/    /' "$WORK/obs-3-recovery.txt"
[ -s "$WORK/obs-3-recovery.txt" ] \
    || fail "[obs] boot 3: no recovery journal on the disk — the guest fx-init predates 4d6a8c2 (rebuild with QEMU_AGENT_REBUILD_INIT=1)"
REC3_N=$(grep -c '^[0-9]' "$WORK/obs-3-recovery.txt" || true)
[ "$REC3_N" = 1 ] \
    || { cat "$WORK/obs-3-recovery.txt"; fail "[obs] boot 3: the journal counts $REC3_N roll-forward(s) (want exactly 1 — this machine's first recovery)"; }
NB3=$(ledger_nonce 3)
grep -Eq "^[0-9]+ $V_C $V_A ([0-9a-f]+|-) $NB3\$" "$WORK/obs-3-recovery.txt" \
    || { cat "$WORK/obs-3-recovery.txt"; fail "[obs] boot 3: the journal line does not name THIS roll-forward (published v$V_C from the failed v$V_A) under BOOT 3's ISSUED NONCE $NB3 — the roll-forward row is not nonce-bound to the boot that wrote it"; }
echo "qemu-agent-observe: [obs] boot 3's .recovery row carries boot 3's host-issued nonce ($NB3) — the roll-forward is bound to the boot that wrote it"
# THE RECOVERY JOURNAL, AGENT HALF: the refused agent's OWN REPORT carries the
# count — the fixture is never dispatched on this boot, so the report is the
# only surface where this agent can see that the machine has recovered.  This
# is the whole point of the journal: "this has happened before", not merely
# "it happened".
grep -qF "1 automatic roll-forward(s) on record" "$WORK/obs-3.log" \
    || { grep -n 'recovery' "$WORK/obs-3.log" | head -4; halt; fail "[obs] boot 3: the refusal report does not carry the recovery count — the refused agent cannot see that this has happened before"; }
S3=$(session_count)
[ "$S3" = "$S1" ] || fail "[obs] boot 3: the session count grew ($S1 -> $S3) — the refused task was STARTED"
MAX3=$(bootlog_max_version "$WORK/obs-3-bootlog.txt")
[ "$MAX3" = "$V_C" ] \
    || { cat "$WORK/obs-3-bootlog.txt"; fail "[obs] boot 3: the store holds v$MAX3 — something WAS activated after the failure (want only the roll-forward's v$V_C)"; }
echo "qemu-agent-observe: [obs] boot 3 GREEN — rolled forward to v$V_C; the restored bracket re-ran the agent"
echo "                    service, which READ ITS OWN RECORD, saw 'v$V_A failed', REPORTED it on the console"
echo "                    and issued NO activation (no new session: $S3, fixture never dispatched)"

echo "=== qemu-agent-observe: [obs] boot 4 — the SAME machine again: the failure is still reported, still nothing is created ==="
boot "$WORK/img-obs.cpio.gz" "$WORK/obs-4.log"
cp "$WORK/obs-4.log" "$EVID/obs-boot4-console.log"
grep -n 'disk store mounted\|rolling forward\|boot-ok\|boot-FAILED\|OBS-AGENT-RAN\|OBSERVED OUTCOME' "$WORK/obs-4.log" | head -12
grep -q "fx-init: disk store mounted (current v$V_C)" "$WORK/obs-4.log" \
    || { tail -30 "$WORK/obs-4.log"; halt; fail "[obs] boot 4: want the disk's CURRENT to still be v$V_C"; }
grep -q "fx-init: boot-ok v$V_C" "$WORK/obs-4.log" \
    || { tail -30 "$WORK/obs-4.log"; halt; fail "[obs] boot 4: want boot-ok v$V_C (the settled generation, booted again)"; }
grep -qF "$OBS_REPORT" "$WORK/obs-4.log" \
    || { tail -40 "$WORK/obs-4.log"; halt; fail "[obs] boot 4: the second boot of the settled generation did not re-report the failure"; }
grep -qF "$TEXT_MARKER" "$WORK/obs-4.log" \
    && { grep -nF "$TEXT_MARKER" "$WORK/obs-4.log" | head -3; halt; fail "[obs] boot 4: the fixture RAN — the harness acted again"; }
halt
read_from_disk "/store/.bootlog" "$WORK/obs-4-bootlog.txt"
cp "$WORK/obs-4-bootlog.txt" "$EVID/obs-boot4-bootlog.txt"
echo "--- [obs] boot 4: the disk .bootlog ---"; sed 's/^/    /' "$WORK/obs-4-bootlog.txt"
# the journal is UNCHANGED by the settled boot: still exactly the one
# roll-forward, and the report still names it (a second data line here would
# mean the "settled" machine recovered AGAIN — the loop leaking).
read_from_disk "/store/.recovery" "$WORK/obs-4-recovery.txt"
cp "$WORK/obs-4-recovery.txt" "$EVID/obs-boot4-recovery.txt"
REC4_N=$(grep -c '^[0-9]' "$WORK/obs-4-recovery.txt" || true)
[ "$REC4_N" = "$REC3_N" ] \
    || { cat "$WORK/obs-4-recovery.txt"; fail "[obs] boot 4: the journal grew ($REC3_N -> $REC4_N) — the settled machine recovered again"; }
grep -qF "1 automatic roll-forward(s) on record" "$WORK/obs-4.log" \
    || { tail -40 "$WORK/obs-4.log"; halt; fail "[obs] boot 4: the re-reported failure does not carry the recovery count"; }
OBS_MAX=$(bootlog_max_version "$WORK/obs-4-bootlog.txt")
OBS_FAILED=$(bootlog_failed_count "$WORK/obs-4-bootlog.txt")
[ "$OBS_MAX" = "$V_C" ] \
    || { cat "$WORK/obs-4-bootlog.txt"; fail "[obs] boot 4: the version climbed to v$OBS_MAX (want v$V_C) — the loop is NOT closed"; }
[ "$OBS_FAILED" = 1 ] \
    || { cat "$WORK/obs-4-bootlog.txt"; fail "[obs] boot 4: $OBS_FAILED failed line(s) (want exactly 1) — the failure is being RE-CREATED"; }
S4=$(session_count)
[ "$S4" = "$S1" ] || fail "[obs] boot 4: the session count grew ($S1 -> $S4) — the task was re-started"
echo "qemu-agent-observe: [obs] SETTLED — max version v$OBS_MAX, exactly $OBS_FAILED failed line, $S4 session(s):"
echo "                    the observing harness never re-issued the failed activation"

# ── THE BOOT-ACCOUNTING DEMONSTRATION, on the REAL guest records ─────────
# Since the enrollment after boot 1 this gate started boots 2, 3 and 4
# (delta 3), EACH under a nonce it minted and recorded in its ledger:
# v$V_A's failed boot, the roll-forward boot that republished the bracket
# as v$V_C, and v$V_C's settled re-boot.  All of it is REAL .bootlog
# growth written by the REAL fx-init inside the guest, under the host's
# own per-boot nonces:
#   (a) it must audit COHERENT with the host's own count and ledger
#       (--boots 4 --nonces) — legitimate growth is the half that makes
#       the check usable;
#   (b) the MOTIVATING FORGE on the same real bootlog — the forged PAIR
#       (in-progress + verdict) that would make the next boot read the
#       crashed generation as good and NOT roll forward — must FIRE.  Two
#       forgers, two fresh extractions of the same disk, the same
#       observation: one wears a nonce the host never issued, one wears
#       boot 4's REAL nonce read off the disk.  BOTH must be caught (the
#       second is the strongest: a disk-readable nonce is not reusable).
if [ -n "$FXSTORE_AUDIT" ]; then
    extract_store "$WORK/audit-ext4"
    # each arm audits against its OWN COPY of the enrollment baseline: a
    # COHERENT run rewrites the observation (advancing host_boots to 4 and
    # collapsing the next window to delta 0), and the forge arms must judge
    # the pair inside the REAL window (boots 2-4) where boot 4's own lines
    # are present to conflict with the reuse
    cp "$WORK/audit-obs.obs" "$WORK/audit-obs-b1.obs"
    cp "$WORK/audit-obs.obs" "$WORK/audit-obs-b2.obs"
    # (a) legitimate growth, accounted by the host's boot delta AND bound
    #     per-boot by the nonce ledger
    FXSTORE_BIN="$FXSTORE_AUDIT" "$AUDIT_BIN" --store "$WORK/audit-ext4/store" \
        --obs-file "$WORK/audit-obs.obs" --boots 4 --nonces "$NONCE_LEDGER" > "$WORK/audit4.out" 2>&1
    _rc=$?
    cp "$WORK/audit4.out" "$EVID/obs-audit-boot4.out"
    [ "$_rc" = 0 ] || { cat "$WORK/audit4.out"; fail "[obs] audit: the real 4-boot history exited $_rc (legitimate growth must stay coherent)"; }
    grep -q 'boot accounting: host boots 1 -> 4 (delta 3)' "$WORK/audit4.out" \
        || fail "[obs] audit: the accounting did not see the host delta: $(grep 'boot accounting' "$WORK/audit4.out")"
    grep -q '^VERDICT: coherent$' "$WORK/audit4.out" \
        || fail "[obs] audit: the real 4-boot history is not coherent"
    grep -q 'UNCLAIMED' "$WORK/audit4.out" \
        && fail "[obs] audit: a nonce was reported unclaimed on a disk where every boot wrote its lines: $(grep 'UNCLAIMED' "$WORK/audit4.out")"
    echo "qemu-agent-observe: [obs] audit: the REAL 3-boot growth since enrollment (v$V_A failed, the roll-forward, the settled re-boot) audits coherent with --boots 4 --nonces (every line nonce-bound)"
    # (b1) the forged PAIR wearing a nonce the host never issued
    extract_store "$WORK/audit-ext4f1"
    printf '%s in-progress 999 deadbad00000001\n%s ok 999 deadbad00000001\n' "$V_A" "$V_A" \
        >> "$WORK/audit-ext4f1/store/.bootlog"
    FXSTORE_BIN="$FXSTORE_AUDIT" "$AUDIT_BIN" --store "$WORK/audit-ext4f1/store" \
        --obs-file "$WORK/audit-obs-b1.obs" --boots 4 --nonces "$NONCE_LEDGER" > "$WORK/audit4f1.out" 2>&1
    _rc=$?
    cp "$WORK/audit4f1.out" "$EVID/obs-audit-forged-pair-invented.out"
    [ "$_rc" = "1" ] || { cat "$WORK/audit4f1.out"; fail "[obs] audit: the forged PAIR (invented nonce) on the real bootlog must be incoherent (exit 1), got $_rc"; }
    grep -q '^INCOHERENT bootlog-unbound-nonce ' "$WORK/audit4f1.out" \
        || fail "[obs] audit: the pair forge fired but not as an unbound nonce: $(grep '^INCOHERENT' "$WORK/audit4f1.out")"
    grep -q '^check previous-observation: pass$' "$WORK/audit4f1.out" \
        || fail "[obs] audit: the forge tripped the prefix comparison too (it is an append — the arm is not isolating the accounting)"
    # (b2) the forged PAIR wearing boot 4's REAL nonce, read off the disk —
    #      the strongest forger: the per-nonce budget, not the ledger's
    #      contents, is what catches it
    NB4=$(ledger_nonce 4)
    extract_store "$WORK/audit-ext4f2"
    printf '%s in-progress 998 %s\n%s ok 998 %s\n' "$V_A" "$NB4" "$V_A" "$NB4" \
        >> "$WORK/audit-ext4f2/store/.bootlog"
    FXSTORE_BIN="$FXSTORE_AUDIT" "$AUDIT_BIN" --store "$WORK/audit-ext4f2/store" \
        --obs-file "$WORK/audit-obs-b2.obs" --boots 4 --nonces "$NONCE_LEDGER" > "$WORK/audit4f2.out" 2>&1
    _rc=$?
    cp "$WORK/audit4f2.out" "$EVID/obs-audit-forged-pair-realnonce.out"
    [ "$_rc" = "1" ] || { cat "$WORK/audit4f2.out"; fail "[obs] audit: the forged PAIR wearing boot 4's real nonce must be incoherent (exit 1), got $_rc"; }
    grep -q '^INCOHERENT bootlog-fabricated-boots ' "$WORK/audit4f2.out" \
        || fail "[obs] audit: the real-nonce pair forge fired but not through the per-nonce budget: $(grep '^INCOHERENT' "$WORK/audit4f2.out")"
    grep -q "carries 2 in-progress line(s)" "$WORK/audit4f2.out" \
        || fail "[obs] audit: the per-nonce finding does not name the reused budget: $(grep '^INCOHERENT bootlog-fabricated' "$WORK/audit4f2.out")"
    # this disk carries the boot-3 roll-forward's .recovery row, whose
    # from-failed IS v$V_A — so recovery-without-failure fires as well (the
    # journal now points at a version whose last verdict says ok): an
    # independent SECOND catch on the (b1) extraction, asserted and stated.
    grep -q '^check recovery-without-failure: failed$' "$WORK/audit4f1.out" \
        || fail "[obs] audit: the real journal points at v$V_A's failure — the forge must also trip recovery-without-failure here"
    echo "qemu-agent-observe: [obs] audit: the forged PAIR on the REAL bootlog fires BOTH ways — an invented nonce as bootlog-unbound-nonce, and boot 4's disk-read REAL nonce as the per-nonce budget (a second independent catch: the real .recovery row names v$V_A)"
fi

# ═══ ARM BLIND — the same fixture with today's harness: the ratchet ═══════
DISK="$WORK/disk-blind.img"; new_disk "$DISK"
echo "=== qemu-agent-observe: [blind] boot 1 — the SAME bracket v$V_B; the blind harness activates the crasher ==="
boot "$WORK/img-blind.cpio.gz" "$WORK/blind-1.log"
cp "$WORK/blind-1.log" "$EVID/blind-boot1-console.log"
grep -n 'disk store mounted\|boot-ok\|boot-FAILED\|OBS-AGENT-RAN\|fakesvc exit' "$WORK/blind-1.log" | head -12
grep -q "fx-init: boot-ok v$V_B" "$WORK/blind-1.log" \
    || { tail -30 "$WORK/blind-1.log"; halt; fail "[blind] boot 1: want boot-ok v$V_B"; }
grep -qF "$TEXT_MARKER" "$WORK/blind-1.log" \
    || { tail -40 "$WORK/blind-1.log"; halt; fail "[blind] boot 1: the blind harness never ran"; }
halt
read_from_disk "/agent-data/attempts.jsonl" "$WORK/blind-1-attempts.txt"
cp "$WORK/blind-1-attempts.txt" "$EVID/blind-boot1-attempts.txt"
V_A2=$(sed -n 's/.* result .* \([0-9][0-9]*\) .*/\1/p' "$WORK/blind-1-attempts.txt" | head -1)
[ -n "$V_A2" ] || { cat "$WORK/blind-1-attempts.txt"; fail "[blind] boot 1: no recorded activation outcome on the disk"; }
[ "$V_A2" -gt "$V_B" ] || fail "[blind] boot 1: v$V_A2 is not above the bracket v$V_B"
echo "qemu-agent-observe: [blind] boot 1 GREEN — the blind harness (recording, but never reading back) activated v$V_A2"

echo "=== qemu-agent-observe: [blind] boot 2 — v$V_A2 FAILS ==="
boot "$WORK/img-blind.cpio.gz" "$WORK/blind-2.log"
cp "$WORK/blind-2.log" "$EVID/blind-boot2-console.log"
grep -q "fx-init: boot-FAILED v$V_A2" "$WORK/blind-2.log" \
    || { tail -30 "$WORK/blind-2.log"; halt; fail "[blind] boot 2: want boot-FAILED v$V_A2"; }
halt
read_from_disk "/store/.bootlog" "$WORK/blind-2-bootlog.txt"
grep -q "^$V_A2 failed " "$WORK/blind-2-bootlog.txt" \
    || { cat "$WORK/blind-2-bootlog.txt"; fail "[blind] boot 2: no '$V_A2 failed' line"; }
echo "--- [blind] boot 2: the disk .bootlog ---"; sed 's/^/    /' "$WORK/blind-2-bootlog.txt"

echo "=== qemu-agent-observe: [blind] boot 3 — roll forward, and the blind harness RE-CREATES the failure ==="
boot "$WORK/img-blind.cpio.gz" "$WORK/blind-3.log"
cp "$WORK/blind-3.log" "$EVID/blind-boot3-console.log"
grep -n 'rolling forward\|boot-ok\|boot-FAILED\|OBS-AGENT-RAN\|OBSERVED OUTCOME' "$WORK/blind-3.log" | head -12
V_D=$(sed -n "s/.*fx-init: stale failed for v$V_A2; rolling forward to v\([0-9][0-9]*\).*/\1/p" "$WORK/blind-3.log" | head -1)
[ -n "$V_D" ] || { tail -30 "$WORK/blind-3.log"; halt; fail "[blind] boot 3: no roll-forward line for v$V_A2"; }
V_E=$(sed -n 's/.*fx-init: boot-ok v\([0-9][0-9]*\).*/\1/p' "$WORK/blind-3.log" | head -1)
[ -n "$V_E" ] || { tail -30 "$WORK/blind-3.log"; halt; fail "[blind] boot 3: no boot-ok after the roll-forward"; }
[ "$V_E" -gt "$V_A2" ] || fail "[blind] boot 3: rolled v$V_E not above v$V_A2"
grep -qF "$TEXT_MARKER" "$WORK/blind-3.log" \
    || { tail -40 "$WORK/blind-3.log"; halt; fail "[blind] boot 3: the restored bracket did not re-run the agent"; }
grep -qF "$OBS_REPORT" "$WORK/blind-3.log" \
    && { halt; fail "[blind] boot 3: the BLIND artifact reported an outcome — the arm is not the pre-fix behaviour"; }
halt
read_from_disk "/agent-data/attempts.jsonl" "$WORK/blind-3-attempts.txt"
cp "$WORK/blind-3-attempts.txt" "$EVID/blind-boot3-attempts.txt"
V_A3=$(sed -n 's/.* result .* \([0-9][0-9]*\) .*/\1/p' "$WORK/blind-3-attempts.txt" | tail -1)
[ -n "$V_A3" ] || { cat "$WORK/blind-3-attempts.txt"; fail "[blind] boot 3: no second recorded activation on the disk"; }
[ "$V_A3" -gt "$V_E" ] \
    || { cat "$WORK/blind-3-attempts.txt"; fail "[blind] boot 3: the blind harness re-activated v$V_A3 which is NOT above the rolled-to v$V_E — the fixture was not re-run"; }
echo "qemu-agent-observe: [blind] boot 3 — rolled forward to v$V_E and the blind harness RE-ACTIVATED: v$V_A3 > v$V_E"

echo "=== qemu-agent-observe: [blind] boot 4 — the re-created failure fails again (a SECOND failed line) ==="
boot "$WORK/img-blind.cpio.gz" "$WORK/blind-4.log"
cp "$WORK/blind-4.log" "$EVID/blind-boot4-console.log"
grep -n 'disk store mounted\|boot-ok\|boot-FAILED\|fakesvc exit' "$WORK/blind-4.log" | head -12
grep -q "fx-init: disk store mounted (current v$V_A3)" "$WORK/blind-4.log" \
    || { tail -30 "$WORK/blind-4.log"; halt; fail "[blind] boot 4: the disk's CURRENT is not the blind harness's v$V_A3"; }
grep -q "fx-init: boot-FAILED v$V_A3" "$WORK/blind-4.log" \
    || { tail -30 "$WORK/blind-4.log"; halt; fail "[blind] boot 4: want boot-FAILED v$V_A3 (the re-created failure)"; }
halt
read_from_disk "/store/.bootlog" "$WORK/blind-4-bootlog.txt"
cp "$WORK/blind-4-bootlog.txt" "$EVID/blind-boot4-bootlog.txt"
echo "--- [blind] boot 4: the disk .bootlog (the RATCHET) ---"; sed 's/^/    /' "$WORK/blind-4-bootlog.txt"
# THE SUBSTRATE HALF IS ARM-INDEPENDENT: the blind arm's fx-init also rolled
# forward (boot 3, before its agent blindly re-activated), so its journal holds
# exactly the one line TOO — the counter counts whether or not anyone reads it.
# The DIFFERENCE between the arms is what the AGENT does with it, and only
# that (asserted above: this arm's harness prints no report at all).
read_from_disk "/store/.recovery" "$WORK/blind-4-recovery.txt"
cp "$WORK/blind-4-recovery.txt" "$EVID/blind-boot4-recovery.txt"
BLIND_REC=$(grep -c '^[0-9]' "$WORK/blind-4-recovery.txt" || true)
[ "$BLIND_REC" -ge 1 ] \
    || { cat "$WORK/blind-4-recovery.txt"; fail "[blind] boot 4: the blind disk's journal is empty — the SUBSTRATE half did not count the blind arm's own roll-forward (fx-init predates 4d6a8c2?)"; }
BLIND_MAX=$(bootlog_max_version "$WORK/blind-4-bootlog.txt")
BLIND_FAILED=$(bootlog_failed_count "$WORK/blind-4-bootlog.txt")
[ "$BLIND_MAX" -gt "$V_E" ] \
    || { cat "$WORK/blind-4-bootlog.txt"; fail "[blind] boot 4: the version did not climb past v$V_E (v$BLIND_MAX)"; }
[ "$BLIND_FAILED" -ge 2 ] \
    || { cat "$WORK/blind-4-bootlog.txt"; fail "[blind] boot 4: only $BLIND_FAILED failed line — no ratchet, this arm measures nothing"; }
echo "qemu-agent-observe: [blind] RATCHETED — max version v$BLIND_MAX (the observing arm stopped at v$V_C),"
echo "                    $BLIND_FAILED failed lines (the observing arm kept 1)"

# ═══ THE DIFFERENCE, ASSERTED ════════════════════════════════════════════
# The two arms ran the SAME fixture, configs, store lineage and boot sequence on
# SEPARATE disks (a fresh disk per arm, so both number their generations from the
# same v_B — the ABSOLUTE numbers are not what distinguishes them; the STORE'S
# GROWTH is).
[ "$BLIND_MAX" -gt "$OBS_MAX" ] \
    || fail "THE ARMS DO NOT DIFFER: blind max v$BLIND_MAX vs observing max v$OBS_MAX"
[ "$BLIND_FAILED" -gt "$OBS_FAILED" ] \
    || fail "THE ARMS DO NOT DIFFER: blind $BLIND_FAILED failed line(s) vs observing $OBS_FAILED"
OBS_VERSIONS=$(awk '{print $1}' "$WORK/obs-4-bootlog.txt" | sort -u | wc -l | tr -d ' ')
BLIND_VERSIONS=$(awk '{print $1}' "$WORK/blind-4-bootlog.txt" | sort -u | wc -l | tr -d ' ')
[ "$BLIND_VERSIONS" -gt "$OBS_VERSIONS" ] \
    || fail "THE ARMS DO NOT DIFFER: $BLIND_VERSIONS distinct generation(s) in the blind store vs $OBS_VERSIONS in the observing one"
# the blind arm's EXTRA generation is the one its own agent created after the
# roll-forward; the observing arm's store stopped growing at the roll-forward.
grep -q "^$V_A3 " "$WORK/blind-4-bootlog.txt" \
    || { cat "$WORK/blind-4-bootlog.txt"; fail "the blind arm's agent-created generation v$V_A3 is not in its own bootlog"; }
grep -q "^$V_A3 " "$WORK/obs-4-bootlog.txt" \
    && { cat "$WORK/obs-4-bootlog.txt"; fail "the observing arm's bootlog holds v$V_A3, a generation only the blind arm's agent created — the arms are not independent"; }
echo "qemu-agent-observe: THE ARMS DIFFER — same fixture, same configs, same store lineage, same boot"
echo "                    sequence, separate disks; only the harness binary differs:"
echo "                      observing: $OBS_FAILED failed line, $OBS_VERSIONS generations, max v$OBS_MAX (the ROLL-FORWARD's), fixture never dispatched"
echo "                      blind    : $BLIND_FAILED failed lines, $BLIND_VERSIONS generations, max v$BLIND_MAX (the AGENT's: v$V_A3 re-created the failure)"

echo
echo "qemu-agent-observe: PASS"
echo "  ARM OBSERVING: bracket v$V_B -> the agent activated v$V_A (recorded durably on the disk, outcome read"
echo "                 back through fx_outcome, which also read the recovery journal as ZERO) -> v$V_A FAILED"
echo "                 ('$V_A failed' in the disk .bootlog) -> the next boot rolled forward to v$V_C (ONE journal"
echo "                 line: published v$V_C from v$V_A) -> the restored bracket re-ran the agent, which READ"
echo "                 ITS OWN RECORD, reported 'THE ACTIVATION THIS HARNESS RECORDED FAILED' WITH the recovery"
echo "                 count (the refused agent SEES this has happened) and issued no"
echo "                 further activation (session count unchanged) -> boot 4: same report, still nothing"
echo "                 created -> SETTLED: max version v$OBS_MAX, $OBS_FAILED failed line."
echo "  ARM BLIND: the SAME sequence on its own disk, with the SAME binary built -DFX_HARNESS_NO_OBSERVE"
echo "             (make blind): the agent re-activated blindly after the roll-forward (v$V_A3 > v$V_E) and"
echo "             the store ratcheted — max version v$BLIND_MAX, $BLIND_FAILED failed lines."
echo "  EVIDENCE: tests/evidence/qemu-agent-observe/ (consoles, disk .bootlogs, the durable records)."
exit 0
